// An epoll based server: a pool of threads, each with its own epoll instance and its own table of
// connections. Every connection stays on the thread that accepted it, so a connection's state needs no locking.
//
// Not fatal: anything a single client can cause (a bad request, a reset connection, a failed setsockopt
// on its socket...) only closes that client. die() is for failing to start up.
//
// To try the server under load:  wrk --latency -t6 -c10000 -d1 http://localhost/bench

BACKLOG               :: 1024;
MAX_EVENTS            :: BACKLOG;
MAX_THREADS           :: 64;

// a connection starts with a buffer this big and grows when a request needs more (up to http_options.max_request_bytes)
REQUEST_BUFFER_INITIAL :: 4 * 1024;
// ... and gives it back after a request if it grew past this, so a single big upload doesn't keep memory for good
REQUEST_BUFFER_KEEP    :: 16 * 1024;

// How many threads are running. Chosen at runtime by http_listen.
thread_count          : s32;

thread_pool           : [MAX_THREADS] Thread;
epoll_fd_pool         : [MAX_THREADS] s32;
epoll_events_pool     : [MAX_THREADS] [MAX_EVENTS] epoll_event;

request_pool          : [MAX_THREADS]Table(Socket, Request);


listen_socket: Socket;
listen_called: bool;

// threads: how many threads handle connections. 0 means half of the processors:
// performance is significantly worse when we don't divide num processors by 2!
// 8700k (6 cores, 12 threads)
// wrk --latency -t6 -c100 -d10 http://localhost
// all processors  # Req/Sec    52.76k
// half of them    # Req/Sec    81.54k
http_listen :: (port: u16 = 80, ip: string = "0.0.0.0", threads: s32 = 0) {
  assert(!listen_called, "cannot call listen multiple times");
  listen_called = true;

  http_common_init();
  signal(SIGPIPE, SIG_IGN); // writing to a connection the client already closed must not kill the process

  thread_count = threads;
  if thread_count <= 0  thread_count = cast(s32) max(1, get_number_of_processors() / 2);
  thread_count = min(thread_count, MAX_THREADS);

  listen_socket = create_listen_socket(port, ip);
  log("HTTP Server listening on %:% (% threads)", ip, port, thread_count);
  init(*threads_lock);

  // spin up the thread pool
  for i: 0 .. thread_count - 1 {
    thread := *thread_pool[i];
    epoll_fd_pool[i] = epoll_create1(0);
    if epoll_fd_pool[i] < 0  die("epoll_create1(0)");
    if !add_to_epoll_fd_list(epoll_fd_pool[i], listen_socket, null, EPOLLIN | EPOLLET /*| EPOLLONESHOT*/)  die("epoll_ctl() listen socket");

    thread.data = xx i;
    threads_running += 1; // no thread is running yet, so no lock
    init(*request_pool[i], BACKLOG+3); // why +3?
    thread_init(thread, thread_pool_proc);
    thread_start(thread);
  }
}

listen_socket_ssl: Socket;
listen_called_ssl: bool;
https_listen :: (port: u16 = 443, ip: string = "0.0.0.0", certificate: string = "", privatekey: string = "") {
  assert(listen_called, "http_listen must be called first for now. because it does setup stuff that i'm lazy to deal with");
  assert(!listen_called_ssl, "cannot call listen multiple times");
  listen_called_ssl = true;

  ssl_init(certificate=certificate, privatekey=privatekey);

  listen_socket_ssl = create_listen_socket(port, ip);
  log("HTTPS Server listening on %:%", ip, port);

  for i: 0 .. thread_count - 1 {
    if !add_to_epoll_fd_list(epoll_fd_pool[i], listen_socket_ssl, null, EPOLLIN | EPOLLET /*| EPOLLONESHOT*/)  die("epoll_ctl() ssl listen socket");
  }
}

create_listen_socket :: (port: u16, ip: string) -> Socket {
  listen_socket := socket(AF_INET, SOCK.SOCK_STREAM | .SOCK_NONBLOCK, 0);
  if listen_socket < 0  die("listen socket()");

  setnonblocking(listen_socket);
  setsockopt(listen_socket, SO_REUSEADDR);
  setsocktcpopt(listen_socket, TCP_NODELAY);

  listen_addr: sockaddr_in;
  listen_addr.sin_family = AF_INET;
  listen_addr.sin_addr.s_addr = inet_addr(to_c_string(ip));
  listen_addr.sin_port = htons(port);
  if bind(listen_socket, cast(*sockaddr)*listen_addr, size_of(type_of(listen_addr))) < 0 {
    die("listen bind()", errno());
  }
  if listen(listen_socket, BACKLOG) < 0  die("listen listen()");

  return listen_socket;
}


thread_pool_proc :: (thread: *Thread) -> s64 {
  ts: Temporary_Storage; context.temporary_storage = *ts;
  thread_id := cast(s32)thread.data;
  epoll_fd := epoll_fd_pool[thread_id];

  client_addr: sockaddr_in;
  client_addr_len: socklen_t = size_of(type_of(client_addr));

  last_sweep := seconds_since_init();

  // poll forever. The 1 second timeout is how we get to look for connections that went quiet.
  while 1 {
    if shutting_down && shutdown_step(thread_id) break;
    epoll_ret := epoll_wait(epoll_fd, xx *epoll_events_pool[thread_id], MAX_EVENTS, ifx shutting_down then cast(s32) 100 else cast(s32) 1000);
    if epoll_ret < 0 {
      if errno() != EINTR  log("epoll_wait() failed: %", errno());
      continue;
    }

    for i: 0 .. epoll_ret-1 {
      event := epoll_events_pool[thread_id][i];
      // mylog("fd:", event.data.fd, "ev:", event.events);
      if event.events == 0 continue; // not sure why this is here, but it is called sometimes
      if event.data.fd <= 2 continue; // are these stdin, out, and err? why are they here

      // received a new event on the listen_socket. this means a client is ready to be accepted
      if event.data.fd == listen_socket || event.data.fd == listen_socket_ssl {
        the_listen_socket := event.data.fd;
        while 1 {
          client_socket := accept(the_listen_socket, cast(*sockaddr)*client_addr, *client_addr_len);

          if client_socket < 0 then break;

          setnonblocking(client_socket);
          try_setsocktcpopt(client_socket, TCP_NODELAY); // failing to set this is not worth losing the connection over
          if !add_to_epoll_fd_list(epoll_fd, client_socket, null, EPOLLIN/* | EPOLLET | EPOLLONESHOT*/) {
            close(client_socket);
            continue;
          }

          if event.data.fd == listen_socket_ssl then ssl_make_socket_ssl(client_socket);

          new_request_from_pool(client_socket, thread_id);
          handle_client_socket_accepted_or_read_ready(client_socket, epoll_fd, thread_id);
        }

        continue;
      }

      // not the listen socket, must be a client_socket ready to read or write ... right?
      // (a hangup or an error is reported as "readable": reading is how we find out what happened)
      if event.events & (EPOLLIN | EPOLLHUP | EPOLLERR) {
        client_socket := event.data.fd;
        handle_client_socket_accepted_or_read_ready(client_socket, epoll_fd, thread_id);
        // add_to_epoll_fd_list(epoll_fd, client_socket, null, EPOLLIN | EPOLLET | EPOLLONESHOT, mod=true);
        continue;
      }

      if event.events & EPOLLOUT {
        client_socket := event.data.fd;
        request := table_find_pointer(*request_pool[thread_id], client_socket);
        if !request || !request.write_data continue;

        continue_write(request);
        if request.write_data.data continue;  // the client still can't take the rest
        if !request.connected continue;       // writing failed and the connection was closed

        // the response is out
        if request.close_after { close_connection(request); continue; }
        reset_for_next_request(request);
        // the client may have pipelined its next request: it's already in our buffer, no epoll event will announce it
        handle_client_socket_accepted_or_read_ready(client_socket, epoll_fd, thread_id);
        continue;
      }
    }

    now := seconds_since_init();
    if now - last_sweep >= 1.0 {
      last_sweep = now;
      close_idle_connections(thread_id, now);
    }

    tfree();
  }

  lock(*threads_lock);
  threads_running -= 1;
  unlock(*threads_lock);
  return 0;
}

// ---------------------------------------------------------------------------------------
// graceful shutdown
//
//   http_listen(...);
//   ... add routes ...
//   http_wait_for_shutdown();   // returns after ctrl-c / SIGTERM, once the requests in progress are answered
//
// or call http_shutdown() yourself. The server stops accepting, answers what is already underway
// (every response now closes its connection), closes idle connections and websockets, and gives up
// on what is still running after timeout_seconds.
// ---------------------------------------------------------------------------------------

threads_running          : s32;
threads_lock             : Mutex;
shutdown_deadline        : float64;
shutdown_signal_received : bool;

http_shutdown :: (timeout_seconds: float64 = 10) {
  if shutting_down return;
  shutdown_deadline = seconds_since_init() + timeout_seconds;
  shutting_down = true;
  log("HTTP Server shutting down");

  // closing the listen sockets takes them out of every epoll set, so nothing new is accepted
  if listen_socket >= 0 { close(listen_socket); listen_socket = -1; }
  if listen_called_ssl && listen_socket_ssl >= 0 { close(listen_socket_ssl); listen_socket_ssl = -1; }

  // the threads leave their loop by themselves, once they are done or past the deadline
  while seconds_since_init() < shutdown_deadline + 2 {
    lock(*threads_lock);
    running := threads_running;
    unlock(*threads_lock);
    if running == 0 break;
    sleep_milliseconds(20);
  }
  log("HTTP Server stopped");
}

shutdown_signal_handler :: (signum: s32) #c_call { shutdown_signal_received = true; }

// blocks until SIGINT (ctrl-c) or SIGTERM arrives, then calls http_shutdown()
http_wait_for_shutdown :: (timeout_seconds: float64 = 10) {
  signal(SIGINT,  shutdown_signal_handler);
  signal(SIGTERM, shutdown_signal_handler);
  while !shutdown_signal_received  sleep_milliseconds(100);
  http_shutdown(timeout_seconds);
}

// one round of closing connections on this thread. true when nothing is left to wait for.
shutdown_step :: (thread_id: s32) -> bool {
  past_deadline := seconds_since_init() > shutdown_deadline;
  busy := 0;
  for *request: request_pool[thread_id] {
    if !request.connected continue;
    in_progress := !request.upgraded && (request.raw.count > 0 || request.write_data.data != null);
    if past_deadline || !in_progress  close_connection(request); else busy += 1;
  }
  return busy == 0;
}

// Slow clients, and clients that connect and never say anything, would otherwise hold their
// connection (and its buffer) forever.
close_idle_connections :: (thread_id: s32, now: float64) {
  for *request: request_pool[thread_id] {
    if !request.connected || request.upgraded continue; // websockets are not timed out here

    // a request that has begun has to finish soon. A quiet keep-alive connection may wait longer.
    limit := ifx request.raw.count > 0 || request.write_data.data then http_options.header_timeout_seconds else http_options.idle_timeout_seconds;
    if limit <= 0 continue;

    if now - request.last_activity > limit  close_connection(request);
  }
}

make_mysocket :: (socket: Socket) -> MySocket {
  mysocket: MySocket;
  mysocket.socket = socket;
  return mysocket;
}

// The state for a connection that was just accepted. The table is indexed by fd, so this slot
// may hold whatever the previous connection on the same fd number left behind: reset all of it.
new_request_from_pool :: (client_socket: Socket, thread_id: s32) -> *Request {
  request: *Request = find_or_add(*request_pool[thread_id], client_socket);

  if request.write_data.data {
    free(request.write_data.data);
    request.write_data.data = null;
  }
  request.write_data.count = 0;
  request.write_bytes_sent = 0;

  request.socket         = make_mysocket(client_socket);
  request.thread_id      = thread_id;
  request.epoll_fd       = epoll_fd_pool[thread_id];
  request.connected      = true;
  request.upgraded       = false;
  request.last_activity  = seconds_since_init();

  if !request.raw.data {
    request.raw = alloc_string(REQUEST_BUFFER_INITIAL);
    request.raw_capacity = REQUEST_BUFFER_INITIAL;
  }
  request.raw.count      = 0;
  request.request_len    = 0;

  reset_request_state(request);
  return request;
}

// Everything about the request that was just handled. Not the connection, and not the bytes in raw.
reset_request_state :: (request: *Request) {
  request.content_length   = 0;
  request.body             = "";
  request.path             = "";
  request.query            = "";
  request.method           = .ANY;
  request.websocket_key    = "";
  request.accept_encoding  = "";
  request.data             = null;
  request.response_sent    = false;
  request.err              = false;
  request.close_after      = false;
  request.expects_continue = false;
  request.continue_sent    = false;
  request.head_parsed      = false;
  request.head_end         = 0;
  request.search_from      = 0;
  request.res_headers.count = 0;
  request.request_id       = "";
  request.session          = null;
  request.compress_quality   = 0;
  request.compress_min_bytes = 0;
  table_reset(*request.locals);

  #if parseheaders table_reset(*request.headers);
  table_reset(*request.params);
}

// Called when a response is finished, on a connection that stays open. If the client sent the
// start of its next request along with this one (pipelining), those bytes are kept.
reset_for_next_request :: (request: *Request) {
  leftover := request.raw.count - request.request_len;
  if request.request_len > 0 && leftover > 0 {
    for i: 0 .. leftover - 1  request.raw.data[i] = request.raw.data[request.request_len + i];
    request.raw.count = leftover;
  } else {
    request.raw.count = 0;
    if request.raw_capacity > REQUEST_BUFFER_KEEP {
      free(request.raw.data);
      request.raw.data = null;
      request.raw = alloc_string(REQUEST_BUFFER_INITIAL);
      request.raw.count = 0;
      request.raw_capacity = REQUEST_BUFFER_INITIAL;
    }
  }
  request.request_len = 0;
  reset_request_state(request);
}

close_connection :: (request: *Request) {
  if !request.connected return;
  request.connected = false;

  // ssl has a massive memory leak when run with high concurrency... this doesn't fix it...
  ssl_delete(request.socket.socket); // i thik this is memory leaking the ssl pointers
  close(request.socket.socket);

  if request.write_data.data {
    free(request.write_data.data);
    request.write_data.data = null;
  }
  request.write_data.count = 0;
}

handle_client_socket_accepted_or_read_ready :: (client_socket: Socket, epoll_fd: s32, thread_id: s32) {
  while 1 {
    request := table_find_pointer(*request_pool[thread_id], client_socket);
    if request == null || !request.connected  return; // a stale event for a connection that is already closed

    // if this socket is a websocket, not a request
    if request.upgraded {
      ws := websocket_find(client_socket);
      if ws  websocket_service(ws);
      return;
    }

    request = read_http_request(client_socket, thread_id);
    if request == null  return; // we're waiting to read, need to come back later
    if request.err {
      close_connection(request);
      return;
    }

    handle_request(request);

    if !request.connected  return;            // writing the response failed
    if request.upgraded  return;              // the websocket code owns this socket from now on
    if request.write_data.data  return;       // the response is only partly written: continue_write finishes it, and then goes on from there
    if request.close_after {
      close_connection(request);
      return;
    }

    reset_for_next_request(request); // reset this requests data when we're done with it
  }
}


Parse_Status :: enum { NEED_MORE; READY; FAILED; }

// Reads from the socket until a whole request is in request.raw, or there's nothing left to read.
// Returns null when more data has to arrive first.
read_http_request :: (socket: Socket, thread_id: s32) -> *Request {
  request: *Request = table_find_pointer(*request_pool[thread_id], socket);
  if request == null  return null;

  while 1 {
    // first look at what we already have: a pipelined request may be complete without reading again
    status := advance_request(request);
    if status == .READY   return request;
    if status == .FAILED {
      request.err = true;
      return request;
    }

    // we need more bytes. make room for them
    if request.raw.count >= request.raw_capacity {
      limit := ifx request.head_parsed then request.head_end + request.content_length else cast(s64) MAX_HEAD_BYTES;
      if request.raw_capacity >= limit {
        fail_request(request, ifx request.head_parsed then cast(u16) 413 else cast(u16) 431);
        return request;
      }
      grow_request_buffer(request, min(request.raw_capacity * 2, limit));
    }

    bytes_received := mysocket_read(request.socket, request.raw.data + request.raw.count, xx(request.raw_capacity - request.raw.count));

    if bytes_received < 0 {
      error := errno();
      if error == EWOULDBLOCK  return null;
      if error == EINTR  continue;
      request.err = true; // connection reset and the like
      return request;
    }
    if bytes_received == 0 { // the client closed the connection
      request.err = true;
      return request;
    }

    request.raw.count += bytes_received;
    request.last_activity = seconds_since_init();
  }

  return request;
}

// Is there a whole request in request.raw yet? Parses the head as soon as it's complete.
advance_request :: (request: *Request) -> Parse_Status {
  if !request.head_parsed {
    from := max(0, request.search_from - 3);
    end := find_head_end(request.raw, from);
    if end == -1 {
      request.search_from = request.raw.count;
      if request.raw.count >= MAX_HEAD_BYTES {
        fail_request(request, 431);
        return .FAILED;
      }
      return .NEED_MORE;
    }

    head_end := end + 4;
    if head_end > MAX_HEAD_BYTES {
      fail_request(request, 431);
      return .FAILED;
    }

    status := parse_request_head(request, head_end);
    if status != 0 {
      fail_request(request, status);
      return .FAILED;
    }
    request.head_end    = head_end;
    request.head_parsed = true;

    total := head_end + request.content_length;
    if total > http_options.max_request_bytes {
      fail_request(request, 413);
      return .FAILED;
    }
    if total > request.raw_capacity {
      grow_request_buffer(request, total);
      // the buffer moved, so everything parse_request_head pointed into it is stale. Same input, same result.
      status = parse_request_head(request, head_end);
      if status != 0 {
        fail_request(request, status);
        return .FAILED;
      }
    }

    // curl sends "Expect: 100-continue" with big bodies and waits a second for this before sending the body
    if request.expects_continue && !request.continue_sent && request.raw.count < total {
      request.continue_sent = true;
      mysocket_write(request.socket, "HTTP/1.1 100 Continue\r\n\r\n");
    }
  }

  total := request.head_end + request.content_length;
  if request.raw.count < total  return .NEED_MORE;

  request.body.data  = request.raw.data + request.head_end;
  request.body.count = request.content_length;
  request.request_len = total;
  return .READY;
}

grow_request_buffer :: (request: *Request, new_capacity: s64) {
  new_data := cast(*u8) alloc(new_capacity);
  memcpy(new_data, request.raw.data, request.raw.count);
  free(request.raw.data);
  request.raw.data = new_data;
  request.raw_capacity = new_capacity;
}

// answer a request we can't or won't handle, and have the connection closed
fail_request :: (request: *Request, status_code: u16) {
  request.res_headers.count = 0;
  request.start_time  = seconds_since_init();
  request.close_after = true;
  request.err = true;
  send_error(request, status_code);
}


continue_write :: (request: *Request) {
  while request.write_bytes_sent < request.write_data.count {
    remaining_bytes_to_write := substr(request.write_data, request.write_bytes_sent);
    bytes_written := mysocket_write(request.socket, remaining_bytes_to_write);

    if bytes_written < 0 {
      if errno() == EINTR continue;
      if errno() == EWOULDBLOCK {
        if !add_to_epoll_fd_list(request.epoll_fd, request.socket.socket, null, EPOLLOUT, mod=true)  close_connection(request);
        return;
      }
      close_connection(request); // the client is gone. Nothing else to do for it
      return;
    }

    request.write_bytes_sent += bytes_written;
    request.last_activity = seconds_since_init();
  }

  free(request.write_data.data); request.write_data.data = null;
  request.write_data.count = 0;
  if !add_to_epoll_fd_list(request.epoll_fd, request.socket.socket, null, EPOLLIN, mod=true)  close_connection(request); // Reset the socket to listen for reads
}


// // todo: async? caching?
// send_file :: (request: *Request, filename: string) {

//   fd := open(to_c_string(filename), O_RDONLY);
//   if fd == -1 return;
//   defer close(fd);

//   stats: stat_t;
//   fstat(fd, *stats);
//   if S_ISDIR(stats.st_mode) {
//     send_file(request, tprint("%/index.html", filename));
//     return;
//   }
//   if !S_ISREG(stats.st_mode) return; // this is not a regular file! (probably a folder), don't sendfile it
//   length := stats.st_size;

//   content_type := extension2contenttype(filename);
//   http_response_headers := tprint("HTTP/1.1 200 OK\r\nConnection: Keep-Alive\r\nContent-Length: %\r\nContent-Type: %; charset=UTF-8\r\nServer: Jai\r\n\r\n", length, content_type);
//   send(request.socket, http_response_headers);
//   sendfile(request.socket, fd, null, xx stats.st_size);

//   request.response_sent = true;
// }





// for the listen socket: the server can't run without these, so it stops
setsockopt :: (socket: s32, option: s32, optval: s32 = 1) {
  if setsockopt(socket, SOL_SOCKET, option, *optval, size_of(type_of(optval))) < 0 {
    die("setsockopt err:", errno(), "socket:", socket, "option:", option, "val:", optval);
  }
}
setsocktcpopt :: (socket: s32, option: s32, optval: s32 = 1) {
  if !try_setsocktcpopt(socket, option, optval) {
    die("setsocktcpopt err:", errno(), "socket:", socket, "option:", option, "val:", optval);
  }
}
// for a client's socket: if it fails (the client may already be gone) the caller carries on
try_setsocktcpopt :: (socket: s32, option: s32, optval: s32 = 1) -> bool {
  return setsockopt(socket, xx IPPROTO.TCP, option, *optval, size_of(type_of(optval))) >= 0;
}
setnonblocking :: (fd: s32) {
  old_option := fcntl(fd, F_GETFL);
  new_option := old_option | O_NONBLOCK;
  fcntl(fd, F_SETFL, new_option);
}

// false if the kernel refused (for a client socket that usually means it's already gone)
add_to_epoll_fd_list :: (epoll_fd: s32, fd: s32, ptr: *void, ep_events: u32, $mod: bool = false) -> bool {
  // mylog("adding to epoll list", fd);
  event: epoll_event;
  if ptr event.data.ptr = ptr;
  else   event.data.fd = fd;
  event.events = ep_events;

  #if !mod return epoll_ctl(epoll_fd, .ADD, fd, *event) == 0;
  #if  mod return epoll_ctl(epoll_fd, .MOD, fd, *event) == 0;
}
// remove_from_epoll_fd_list :: (fd: s32) {
//   if epoll_ctl(epoll_fd, EPOLL_CTL_DEL, fd, null)  die("remove epoll_ctl()");
// }




get_sockaddr_in_from_socket :: (socket: s32) -> sockaddr_in {
  addr_in: sockaddr_in;
  sizeof_sockaddr_in : u32 = size_of(type_of(addr_in));
  getpeername(socket, cast(*sockaddr)*addr_in, *sizeof_sockaddr_in);
  return addr_in;
}
get_ip_string_from_socket :: (socket: s32) -> string {
  addr_in := get_sockaddr_in_from_socket(socket);

  INET_ADDRSTRLEN :: 16;
  cstr := talloc(INET_ADDRSTRLEN);
  inet_ntop(AF_INET, *addr_in.sin_addr.s_addr, cstr, INET_ADDRSTRLEN);
  return fromcstr(cstr);
}





#import,dir "modules/openssl";
#import,dir "modules/mybasic";
#import,dir "modules/mysocket";

#import "POSIX";
#import "Linux";
#import "File";
#import "Thread";
#import "System";

TCP_NODELAY    :: 1;
SO_KEEPALIVE   :: 0x0008;
