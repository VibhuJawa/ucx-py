# Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
# See file LICENSE for terms.
# cython: language_level=3

import asyncio
import uuid
import socket
from functools import reduce
import operator
import numpy as np
from ucp_tiny_dep cimport *
from ..exceptions import UCXError, UCXCloseError
from .send_recv import tag_send, tag_recv, stream_send, stream_recv


def assert_error(exp, msg):
    """ 
    Use this instead of assert() instead of cython 
    functions to pass along a more useful message
    """
    if not exp:
        raise UCXError(msg)


cdef assert_ucs_status(ucs_status_t status, msg_context=None):
    if status != UCS_OK:
        msg = "[%s] " % msg_context if msg_context is not None else ""
        msg += (<object> ucs_status_string(status)).decode("utf-8") 
        raise UCXError(msg)


cdef struct _listener_callback_args:
    ucp_worker_h ucp_worker
    PyObject *py_func


def asyncio_handle_exception(loop, context):
    msg = context.get("exception", context["message"])
    print("Ignored Exception: %s" % msg)


async def listener_handler(ucp_endpoint, ucp_worker, func):
    tags = np.empty(2, dtype="uint64")
    await stream_recv(ucp_endpoint, tags, tags.nbytes)

    ep = Endpoint(ucp_endpoint, ucp_worker, tags[0], tags[1])

    print("listener_handler() server: %s peer: %s" %(hex(tags[1]), hex(tags[0])))

    if asyncio.iscoroutinefunction(func):
        #TODO: exceptions in this callback is never showed when no 
        #      get_exception_handler() is set. 
        #      Is this the correct way to handle exceptions in asyncio?
        #      Do we need to set this in other places?
        loop = asyncio.get_running_loop()
        if loop.get_exception_handler() is None:
            loop.set_exception_handler(asyncio_handle_exception)
        await func(ep)
    else:
        func(ep)


cdef void _listener_callback(ucp_ep_h ep, void *args):
    cdef _listener_callback_args *a = <_listener_callback_args *> args
    cdef object func = <object> a.py_func

    asyncio.create_task(listener_handler(PyLong_FromVoidPtr(<void*>ep), PyLong_FromVoidPtr(<void*>a.ucp_worker), func))


cdef void ucp_request_init(void* request):
    cdef ucp_request *req = <ucp_request*> request
    req.finished = False
    req.future = NULL
    req.expected_receive = 0


def get_buffer_info(buffer, requested_nbytes=None, check_writable=False):
    """Returns tuple(nbytes, data pointer) of the buffer
    if `requested_nbytes` is not None, the returned nbytes is `requested_nbytes` 
    """
    array_interface = None
    if hasattr(buffer, "__cuda_array_interface__"):
        array_interface = buffer.__cuda_array_interface__
    elif hasattr(buffer, "__array_interface__"):
        array_interface = buffer.__array_interface__
    else:
        raise ValueError("buffer must expose cuda/array interface")        

    # TODO: check that data is contiguous
    itemsize = int(np.dtype(array_interface['typestr']).itemsize)
    # Making sure that the elements in shape is integers
    shape = [int(s) for s in array_interface['shape']]
    nbytes = reduce(operator.mul, shape, 1) * itemsize
    data_ptr, data_readonly = array_interface['data']

    # Workaround for numba giving None, rather than an 0.
    # https://github.com/cupy/cupy/issues/2104 for more info.
    if data_ptr is None:
        data_ptr = 0
    
    if data_ptr == 0:
        raise NotImplementedError("zero-sized buffers isn't supported")

    if check_writable and data_readonly:    
        raise ValueError("writing to readonly buffer!")

    if requested_nbytes is not None:
        if requested_nbytes > nbytes:
            raise ValueError("the nbytes is greater than the size of the buffer!")
        else:
            nbytes = requested_nbytes
    return (nbytes, data_ptr)


cdef class Listener:
    cdef: 
        cdef ucp_listener_h _ucp_listener
        cdef uint16_t port
    
    def __init__(self, port):
        self.port = port

    @property
    def port(self):
        return self.port

    def __del__(self):
        ucp_listener_destroy(self._ucp_listener)

    

cdef class ApplicationContext:
    cdef:
        ucp_context_h context
        ucp_worker_h worker  # For now, a application context only has one worker
        int epoll_fd
        object all_epoll_binded_to_event_loop

    def __cinit__(self):
        cdef ucp_params_t ucp_params
        cdef ucp_worker_params_t worker_params        
        cdef ucp_config_t *config
        cdef ucs_status_t status
        self.all_epoll_binded_to_event_loop = set()

        cdef unsigned int a, b, c
        ucp_get_version(&a, &b, &c)
        print("UCP Version: %d.%d.%d" % (a, b, c))

        memset(&ucp_params, 0, sizeof(ucp_params))
        ucp_params.field_mask   = UCP_PARAM_FIELD_FEATURES | UCP_PARAM_FIELD_REQUEST_SIZE | UCP_PARAM_FIELD_REQUEST_INIT
        ucp_params.features     = UCP_FEATURE_TAG | UCP_FEATURE_WAKEUP | UCP_FEATURE_STREAM
        ucp_params.request_size = sizeof(ucp_request)
        ucp_params.request_init = ucp_request_init
        status = ucp_config_read(NULL, NULL, &config)
        assert_ucs_status(status)
        
        status = ucp_init(&ucp_params, config, &self.context)
        assert_ucs_status(status)
        
        worker_params.field_mask  = UCP_WORKER_PARAM_FIELD_THREAD_MODE
        worker_params.thread_mode = UCS_THREAD_MODE_MULTI
        status = ucp_worker_create(self.context, &worker_params, &self.worker)
        assert_ucs_status(status)

        cdef int ucp_epoll_fd
        status = ucp_worker_get_efd(self.worker, &ucp_epoll_fd)
        assert_ucs_status(status)

        self.epoll_fd = epoll_create(1)
        cdef epoll_event ev
        ev.data.fd = ucp_epoll_fd
        ev.events = EPOLLIN 
        cdef int err = epoll_ctl(self.epoll_fd, EPOLL_CTL_ADD, ucp_epoll_fd, &ev)
        assert(err == 0)

        ucp_config_release(config)

    
    def create_listener(self, callback_func, port=None):
        self._bind_epoll_fd_to_event_loop()
        if port in (None, 0):
            # Ref https://unix.stackexchange.com/a/132524
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.bind(('', 0))
            port = s.getsockname()[1]
            s.close()
        
        cdef _listener_callback_args *args = <_listener_callback_args*> malloc(sizeof(_listener_callback_args))
        args.ucp_worker = self.worker
        args.py_func = <PyObject*> callback_func
        Py_INCREF(callback_func)

        cdef ucp_listener_params_t params = c_util_get_ucp_listener_params(port, _listener_callback, <void*> args)
        print("create_listener() - Start listening on port %d" % port)
        listener = Listener(port)
        cdef ucs_status_t status = ucp_listener_create(self.worker, &params, &listener._ucp_listener)
        c_util_get_ucp_listener_params_free(&params)
        assert_ucs_status(status)
        return listener


    async def create_endpoint(self, str ip_address, port):
        self._bind_epoll_fd_to_event_loop()
        
        cdef ucp_ep_params_t params = c_util_get_ucp_ep_params(ip_address.encode(), port)
        cdef ucp_ep_h ucp_ep
        cdef ucs_status_t status = ucp_ep_create(self.worker, &params, &ucp_ep)
        c_util_get_ucp_ep_params_free(&params)
        assert_ucs_status(status)
        ret = Endpoint(
            PyLong_FromVoidPtr(<void*> ucp_ep),
            PyLong_FromVoidPtr(<void*> self.worker),
            np.uint64(hash(uuid.uuid4())),
            np.uint64(hash(uuid.uuid4())),
        )
        tags = np.array([ret._recv_tag, ret._send_tag], dtype="uint64")
        await stream_send(ret._ucp_endpoint, tags, tags.nbytes)
        return ret


    cdef _progress(self):
        while ucp_worker_progress(self.worker) != 0:
            pass


    def progress(self):
        self._progress()


    def _bind_epoll_fd_to_event_loop(self):
        loop = asyncio.get_event_loop()
        if loop not in self.all_epoll_binded_to_event_loop: 
            print("ApplicationContext - add event loop reader: ", id(loop))
            loop.add_reader(self.epoll_fd, self.progress)
            self.all_epoll_binded_to_event_loop.add(loop)


class Endpoint:

    def __init__(self, ucp_endpoint, ucp_worker, send_tag, recv_tag):
        self._ucp_endpoint = ucp_endpoint
        self._ucp_worker = ucp_worker
        self._send_tag = send_tag
        self._recv_tag = recv_tag
        self._send_count = 0
        self._recv_count = 0

    @property
    def uid(self):
        return self._recv_tag

    async def send(self, buffer, nbytes=None):
        nbytes, _ = get_buffer_info(buffer, requested_nbytes=nbytes, check_writable=False)
        uid = abs(hash("%d%d%d%d" % (self._send_count, nbytes, self._recv_tag, self._send_tag)))
        print("[UCX Comm] %s ==#%03d=> %s hash: %s nbytes: %d" % (hex(self._recv_tag), self._send_count, hex(self._send_tag), hex(uid), nbytes))               
        return await tag_send(self._ucp_endpoint, buffer, nbytes, self._send_tag)

    async def recv(self, buffer, nbytes=None):
        nbytes, _ = get_buffer_info(buffer, requested_nbytes=nbytes, check_writable=True)
        uid = abs(hash("%d%d%d%d" % (self._recv_count, nbytes, self._send_tag, self._recv_tag)))          
        print("[UCX Comm] %s <=#%03d== %s hash: %s nbytes: %d" % (hex(self._recv_tag), self._recv_count, hex(self._send_tag), hex(uid), nbytes))
        self._recv_count += 1
        return await tag_recv(self._ucp_worker, buffer, nbytes, self._recv_tag)    

    def pprint_ep(self):
        ucp_ep_print_info(<ucp_ep_h>PyLong_AsVoidPtr(self._ucp_ep), stdout)
