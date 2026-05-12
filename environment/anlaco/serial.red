Red [
	Title:   "Serial Port Client for Red"
	Author:  "ANLACO"
	File:    %serial.red
	Tabs:    4
	Rights:  "Copyright (C) 2026 ANLACO. All rights reserved."
	License: {
		BSD-3-Clause. Portions ported from Red-Serial
		(Copyright (C) 2026 ANLACO, BSD-3-Clause).
	}
	Version: 0.1.0
	Notes: {
		Native serial port (RS-232/485/USB-CDC) module.
		Non-blocking cooperative I/O, single-port instance.
		Linux only in v0.1. Windows/macOS pending v0.2+.
		User must belong to group dialout:
		  sudo usermod -aG dialout $USER  (re-login required)
	}
]

serial: context [
	open?:      false
	INVALID_FD: -1
	timeout-ms: 1000		;-- default per-byte wait for read-line (ms)

	#system [
		#either OS = 'Linux [

			;-- ==============================================================
			;-- LIBC imports
			;-- ==============================================================

			#import [
				LIBC-file cdecl [
					serial-libc-open: "open" [
						path        [c-string!]
						flags       [integer!]
						return:     [integer!]
					]
					serial-libc-close: "close" [
						fd          [integer!]
						return:     [integer!]
					]
					serial-libc-read: "read" [
						fd          [integer!]
						buf         [byte-ptr!]
						count       [integer!]
						return:     [integer!]
					]
					serial-libc-write: "write" [
						fd          [integer!]
						buf         [byte-ptr!]
						count       [integer!]
						return:     [integer!]
					]
					serial-ioctl: "ioctl" [
						[variadic]
						return:     [integer!]
					]
					serial-tcdrain: "tcdrain" [
						fd          [integer!]
						return:     [integer!]
					]
					serial-poll: "poll" [
						fds         [byte-ptr!]
						nfds        [integer!]
						timeout     [integer!]
						return:     [integer!]
					]
					serial-errno-loc: "__errno_location" [
						return:     [int-ptr!]
					]
				]
			]

			;-- ==============================================================
			;-- File / fcntl flags
			;-- ==============================================================

			#define SER_O_RDWR      2
			#define SER_O_NOCTTY    256

			;-- ==============================================================
			;-- Termios flags
			;-- ==============================================================

			#define TCSANOW         0
			#define IGNPAR          4
			#define INPCK           16
			#define IXON            1024
			#define IXOFF           4096
			#define CSIZE           48
			#define CS5             0
			#define CS6             16
			#define CS7             32
			#define CS8             48
			#define CSTOPB          64
			#define CREAD           128
			#define PARENB          256
			#define PARODD          512
			#define CLOCAL          2048
			#define CRTSCTS         80000000h

			;-- ==============================================================
			;-- Baudrate constants (Linux termios)
			;-- ==============================================================

			#define B50             1
			#define B75             2
			#define B110            3
			#define B300            7
			#define B600            8
			#define B1200           9
			#define B2400           11
			#define B4800           12
			#define B9600           13
			#define B19200          14
			#define B38400          15
			#define B57600          4097
			#define B115200         4098
			#define B230400         4099
			#define B460800         4100
			#define B500000         4101
			#define B576000         4102
			#define B921600         4103
			#define B1000000        4104
			#define B1152000        4105
			#define B1500000        4106
			#define B2000000        4107
			#define B2500000        4108
			#define B3000000        4109
			#define B3500000        4110
			#define B4000000        4111

			;-- ==============================================================
			;-- ioctl codes
			;-- ==============================================================

			#define TCGETS          5401h
			#define TCSETS          5402h
			#define TCFLSH          540Bh
			#define TIOCEXCL        540Ch
			#define TIOCNXCL        540Dh
			#define TIOCMGET        5415h
			#define TIOCMBIS        5416h
			#define TIOCMBIC        5417h
			#define FIONREAD        541Bh
			#define TCIOFLUSH       2
			#define TCIFLUSH        0
			#define TCOFLUSH        1

			;-- Modem control bits
			#define TIOCM_DTR       2
			#define TIOCM_RTS       4
			#define TIOCM_CTS       32
			#define TIOCM_CD        64
			#define TIOCM_RI        128
			#define TIOCM_DSR       256

			;-- poll
			#define SER_POLLIN      0001h

			;-- ==============================================================
			;-- Structs
			;-- ==============================================================

			serial-termios!: alias struct! [
				c_iflag     [integer!]
				c_oflag     [integer!]
				c_cflag     [integer!]
				c_lflag     [integer!]
				c_line      [byte!]
				c_cc1       [integer!]	;-- cc bytes  0-3
				c_cc2       [integer!]	;-- cc bytes  4-7  (VTIME=5, VMIN=6)
				c_cc3       [integer!]	;-- cc bytes  8-11
				c_cc4       [integer!]	;-- cc bytes 12-15
				c_cc5       [integer!]	;-- cc bytes 16-19
				c_cc6       [integer!]	;-- cc bytes 20-23
				c_cc7       [integer!]	;-- cc bytes 24-27
				c_cc8       [integer!]	;-- cc bytes 28-31
				c_ispeed    [integer!]
				c_ospeed    [integer!]
			]

			ser-pollfd!: alias struct! [
				fd          [integer!]
				events      [integer!]
			]

			;-- ==============================================================
			;-- State
			;-- ==============================================================

			serial-fd:    -1
			serial-errno: 0

			;-- ==============================================================
			;-- Internal helpers
			;-- ==============================================================

			ser-get-errno: func [
				return: [integer!]
				/local p [int-ptr!]
			][
				p: serial-errno-loc
				p/value
			]

			ser-baudrate-to-speed: func [
				baud    [integer!]
				return: [integer!]
			][
				switch baud [
					50       [B50]
					75       [B75]
					110      [B110]
					300      [B300]
					600      [B600]
					1200     [B1200]
					2400     [B2400]
					4800     [B4800]
					9600     [B9600]
					19200    [B19200]
					38400    [B38400]
					57600    [B57600]
					115200   [B115200]
					230400   [B230400]
					460800   [B460800]
					500000   [B500000]
					576000   [B576000]
					921600   [B921600]
					1000000  [B1000000]
					1152000  [B1152000]
					1500000  [B1500000]
					2000000  [B2000000]
					2500000  [B2500000]
					3000000  [B3000000]
					3500000  [B3500000]
					4000000  [B4000000]
					default  [B9600]
				]
			]

			;-- ==============================================================
			;-- Open / close
			;-- ==============================================================

			ser-open: func [
				device  [c-string!]
				return: [integer!]
				/local fd [integer!]
			][
				fd: serial-libc-open device (SER_O_RDWR or SER_O_NOCTTY)
				if fd < 0 [
					serial-errno: ser-get-errno
					return -1
				]
				serial-ioctl [fd TIOCEXCL]
				serial-fd: fd
				0
			]

			ser-close: func [
				return: [logic!]
			][
				if serial-fd = -1 [return true]
				serial-ioctl [serial-fd TIOCNXCL]
				serial-tcdrain serial-fd
				serial-libc-close serial-fd
				serial-fd: -1
				true
			]

			;-- ==============================================================
			;-- Configure
			;-- ==============================================================

			ser-configure: func [
				baud    [integer!]
				bits    [integer!]
				par     [integer!]
				stop    [integer!]
				flow    [integer!]
				return: [logic!]
				/local
					tio-ptr [byte-ptr!]
					tio     [serial-termios!]
					speed   [integer!]
					cflag   [integer!]
					result  [integer!]
			][
				if serial-fd = -1 [return false]
				tio-ptr: allocate size? serial-termios!
				if tio-ptr = null [return false]
				tio: as serial-termios! tio-ptr

				result: serial-ioctl [serial-fd TCGETS tio-ptr]
				if result < 0 [
					free tio-ptr
					serial-errno: ser-get-errno
					return false
				]

				;-- raw mode: disable all processing
				tio/c_iflag: IGNPAR
				tio/c_oflag: 0
				tio/c_lflag: 0
				tio/c_cflag: CREAD or CLOCAL

				;-- data bits
				cflag: switch bits [5 [CS5] 6 [CS6] 7 [CS7] default [CS8]]
				tio/c_cflag: tio/c_cflag or cflag

				;-- parity
				switch par [
					1 [		;-- odd
						tio/c_cflag: tio/c_cflag or PARENB or PARODD
						tio/c_iflag: tio/c_iflag or INPCK
					]
					2 [		;-- even
						tio/c_cflag: tio/c_cflag or PARENB
						tio/c_iflag: tio/c_iflag or INPCK
					]
					default []
				]

				;-- stop bits
				if stop = 2 [tio/c_cflag: tio/c_cflag or CSTOPB]

				;-- flow control
				switch flow [
					1 [tio/c_iflag: tio/c_iflag or IXON or IXOFF]	;-- xon/xoff
					2 [tio/c_cflag: tio/c_cflag or CRTSCTS]		;-- rts/cts
					default []
				]

				;-- VMIN=0 VTIME=0: fully non-blocking; timeouts via poll at Red level
				tio/c_cc2: 0

				;-- baudrate via c_ispeed/c_ospeed (cfsetispeed equivalent on Linux)
				speed: ser-baudrate-to-speed baud
				tio/c_ispeed: speed
				tio/c_ospeed: speed

				serial-ioctl [serial-fd TCFLSH TCIOFLUSH]
				result: serial-ioctl [serial-fd TCSETS tio-ptr]
				free tio-ptr

				if result < 0 [
					serial-errno: ser-get-errno
					return false
				]
				true
			]

			;-- ==============================================================
			;-- I/O
			;-- ==============================================================

			ser-write: func [
				data    [byte-ptr!]
				length  [integer!]
				return: [integer!]
				/local n [integer!]
			][
				if serial-fd = -1 [return -1]
				n: serial-libc-write serial-fd data length
				if n < 0 [serial-errno: ser-get-errno]
				n
			]

			ser-read: func [
				buffer  [byte-ptr!]
				size    [integer!]
				return: [integer!]
				/local n err [integer!]
			][
				if serial-fd = -1 [return -1]
				n: serial-libc-read serial-fd buffer size
				if n < 0 [
					err: ser-get-errno
					if any [err = 11 err = 35] [return 0]	;-- EAGAIN/EWOULDBLOCK
					serial-errno: err
				]
				n
			]

			ser-read-byte: func [
				return: [integer!]
				/local buf [byte-ptr!] n b [integer!]
			][
				if serial-fd = -1 [return -1]
				buf: allocate 1
				n: serial-libc-read serial-fd buf 1
				b: either n = 1 [as integer! buf/1][-1]
				free buf
				b
			]

			;-- ==============================================================
			;-- Poll / available
			;-- ==============================================================

			ser-available: func [
				return: [integer!]
				/local count result [integer!]
			][
				if serial-fd = -1 [return 0]
				count: 0
				result: serial-ioctl [serial-fd FIONREAD :count]
				either result < 0 [0][count]
			]

			ser-readable: func [
				timeout-ms  [integer!]
				return:     [logic!]
				/local
					pfd     [ser-pollfd!]
					result  [integer!]
			][
				if serial-fd = -1 [return false]
				pfd: declare ser-pollfd!
				pfd/fd: serial-fd
				pfd/events: SER_POLLIN
				result: serial-poll (as byte-ptr! pfd) 1 timeout-ms
				result > 0
			]

			;-- ==============================================================
			;-- Flush / drain
			;-- ==============================================================

			ser-flush: func [
				in?     [logic!]
				out?    [logic!]
				return: [logic!]
				/local queue [integer!]
			][
				if serial-fd = -1 [return false]
				either all [in? out?] [queue: TCIOFLUSH][
					either in? [queue: TCIFLUSH][queue: TCOFLUSH]
				]
				serial-ioctl [serial-fd TCFLSH queue]
				true
			]

			ser-drain: func [
				return: [logic!]
			][
				if serial-fd = -1 [return false]
				serial-tcdrain serial-fd
				true
			]

			;-- ==============================================================
			;-- Modem / control lines
			;-- ==============================================================

			ser-set-dtr: func [
				state   [logic!]
				return: [logic!]
				/local flags [integer!]
			][
				if serial-fd = -1 [return false]
				flags: TIOCM_DTR
				either state [
					serial-ioctl [serial-fd TIOCMBIS :flags]
				][
					serial-ioctl [serial-fd TIOCMBIC :flags]
				]
				true
			]

			ser-set-rts: func [
				state   [logic!]
				return: [logic!]
				/local flags [integer!]
			][
				if serial-fd = -1 [return false]
				flags: TIOCM_RTS
				either state [
					serial-ioctl [serial-fd TIOCMBIS :flags]
				][
					serial-ioctl [serial-fd TIOCMBIC :flags]
				]
				true
			]

			ser-get-modem-bits: func [
				return: [integer!]
				/local flags result [integer!]
			][
				if serial-fd = -1 [return -1]
				flags: 0
				result: serial-ioctl [serial-fd TIOCMGET :flags]
				either result < 0 [-1][flags]
			]

			ser-get-cts: func [return: [logic!] /local b [integer!]][
				b: ser-get-modem-bits
				if b < 0 [return false]
				(b and TIOCM_CTS) <> 0
			]

			ser-get-dsr: func [return: [logic!] /local b [integer!]][
				b: ser-get-modem-bits
				if b < 0 [return false]
				(b and TIOCM_DSR) <> 0
			]

			ser-get-cd: func [return: [logic!] /local b [integer!]][
				b: ser-get-modem-bits
				if b < 0 [return false]
				(b and TIOCM_CD) <> 0
			]

			ser-get-ri: func [return: [logic!] /local b [integer!]][
				b: ser-get-modem-bits
				if b < 0 [return false]
				(b and TIOCM_RI) <> 0
			]

			ser-last-error: func [return: [integer!]][serial-errno]

		][
			;-- ==============================================================
			;-- Non-Linux stubs (v0.2+: Windows, macOS)
			;-- ==============================================================

			serial-fd:    -1
			serial-errno: 0

			ser-open:           func [device [c-string!] return: [integer!]][-1]
			ser-close:          func [return: [logic!]][true]
			ser-configure:      func [baud [integer!] bits [integer!] par [integer!] stop [integer!] flow [integer!] return: [logic!]][false]
			ser-write:          func [data [byte-ptr!] length [integer!] return: [integer!]][-1]
			ser-read:           func [buffer [byte-ptr!] size [integer!] return: [integer!]][-1]
			ser-read-byte:      func [return: [integer!]][-1]
			ser-available:      func [return: [integer!]][0]
			ser-readable:       func [timeout-ms [integer!] return: [logic!]][false]
			ser-flush:          func [in? [logic!] out? [logic!] return: [logic!]][false]
			ser-drain:          func [return: [logic!]][false]
			ser-set-dtr:        func [state [logic!] return: [logic!]][false]
			ser-set-rts:        func [state [logic!] return: [logic!]][false]
			ser-get-cts:        func [return: [logic!]][false]
			ser-get-dsr:        func [return: [logic!]][false]
			ser-get-cd:         func [return: [logic!]][false]
			ser-get-ri:         func [return: [logic!]][false]
			ser-last-error:     func [return: [integer!]][0]
		]
	]

	;-- ==========================================================================
	;-- Routine bridges
	;-- ==========================================================================

	_open: routine [
		device  [binary!]
		baud    [integer!]
		bits    [integer!]
		par     [integer!]
		stop    [integer!]
		flow    [integer!]
		return: [logic!]
		/local
			dev     [c-string!]
			result  [integer!]
	][
		dev: as c-string! binary/rs-head device
		result: ser-open dev
		if result <> 0 [return false]
		ser-configure baud bits par stop flow
	]

	_configure: routine [
		baud    [integer!]
		bits    [integer!]
		par     [integer!]
		stop    [integer!]
		flow    [integer!]
		return: [logic!]
	][
		ser-configure baud bits par stop flow
	]

	_write: routine [
		data    [binary!]
		len     [integer!]
		return: [integer!]
		/local buf [byte-ptr!]
	][
		buf: binary/rs-head data
		ser-write buf len
	]

	_read: routine [
		buffer  [binary!]
		size    [integer!]
		return: [integer!]
		/local buf [byte-ptr!]
	][
		buf: binary/rs-head buffer
		ser-read buf size
	]

	_read-byte: routine [
		return: [integer!]
	][
		ser-read-byte
	]

	_available: routine [
		return: [integer!]
	][
		ser-available
	]

	_readable: routine [
		timeout-ms  [integer!]
		return:     [logic!]
	][
		ser-readable timeout-ms
	]

	_close: routine [
		return: [logic!]
	][
		ser-close
	]

	_flush: routine [
		in?     [logic!]
		out?    [logic!]
		return: [logic!]
	][
		ser-flush in? out?
	]

	_drain: routine [
		return: [logic!]
	][
		ser-drain
	]

	_set-dtr: routine [
		state   [logic!]
		return: [logic!]
	][
		ser-set-dtr state
	]

	_set-rts: routine [
		state   [logic!]
		return: [logic!]
	][
		ser-set-rts state
	]

	_get-cts: routine [
		return: [logic!]
	][
		ser-get-cts
	]

	_get-dsr: routine [
		return: [logic!]
	][
		ser-get-dsr
	]

	_get-cd: routine [
		return: [logic!]
	][
		ser-get-cd
	]

	_get-ri: routine [
		return: [logic!]
	][
		ser-get-ri
	]

	_last-error: routine [
		return: [integer!]
	][
		ser-last-error
	]

	;-- ==========================================================================
	;-- Public API
	;-- ==========================================================================

	open: func [
		"Opens a serial port (default: 9600 8N1 no flow)"
		device  [string! file!] "Device path e.g. /dev/ttyUSB0"
		/baud   b   [integer!]  "Baudrate"
		/bits   db  [integer!]  "Data bits 5-8"
		/parity p   [integer!]  "0=none 1=odd 2=even"
		/stop   s   [integer!]  "Stop bits 1 or 2"
		/flow   f   [integer!]  "0=none 1=xon/xoff 2=rts/cts"
		return: [logic!]
		/local dev-str dev-bin
	][
		if open? [close]
		dev-str: either file? device [to string! device][device]
		dev-bin: append to binary! dev-str #{00}
		either _open dev-bin
			any [b 9600]
			any [db 8]
			any [p 0]
			any [s 1]
			any [f 0]
		[
			open?: true
			true
		][
			print ["Error: could not open serial port" dev-str]
			false
		]
	]

	configure: func [
		"Reconfigures the open serial port"
		/baud          b [integer!] "Baudrate"
		/bits          d [integer!] "Data bits 5-8"
		/parity        p [integer!] "0=none 1=odd 2=even"
		/stop-bits     s [integer!] "Stop bits 1 or 2"
		/flow-control  f [integer!] "0=none 1=xon/xoff 2=rts/cts"
		return: [logic!]
	][
		if not open? [
			print "Error: no serial port open"
			return false
		]
		_configure
			any [b 9600]
			any [d 8]
			any [p 0]
			any [s 1]
			any [f 0]
	]

	write: func [
		"Writes data to the serial port"
		data    [string! binary! char! integer!]
		return: [logic!]
		/local buf n
	][
		if not open? [
			print "Error: no serial port open"
			return false
		]
		buf: case [
			binary?  data [data]
			string?  data [to binary! data]
			char?    data [to binary! to string! data]
			integer? data [to binary! to string! to char! data]
		]
		n: _write buf length? buf
		either n >= 0 [true][
			print "Error: write failed"
			false
		]
	]

	read: func [
		"Reads up to size bytes; returns binary! or none if no data"
		size    [integer!]
		return: [binary! none!]
		/local buf n
	][
		if not open? [return none]
		buf: make binary! size
		insert/dup buf #{00} size
		n: _read buf size
		either n > 0 [copy/part buf n][none]
	]

	read-line: func [
		"Reads characters until newline (LF by default)"
		/terminator term [string!] "Custom line terminator"
		return: [string! none!]
		/local line b term-byte
	][
		if not open? [return none]
		line:      make string! 128
		term-byte: either terminator [to integer! first term][10]
		forever [
			b: _read-byte
			case [
				b = term-byte [break]
				b = -1        [if not _readable timeout-ms [break]]
				b <> 13       [append line to char! b]
			]
		]
		either empty? line [none][line]
	]

	available?: func [
		"Returns number of bytes waiting in the RX buffer"
		return: [integer!]
	][
		either open? [_available][0]
	]

	readable?: func [
		"Returns true if data is available right now (non-blocking)"
		return: [logic!]
	][
		if not open? [return false]
		_readable 0
	]

	set-timeout: func [
		"Sets the per-byte wait used by read-line (milliseconds)"
		ms [integer!]
		return: [logic!]
	][
		timeout-ms: ms
		true
	]

	close: func [
		"Closes the serial port"
		return: [logic!]
	][
		if open? [
			_close
			open?: false
		]
		true
	]

	set-dtr: func [
		"Sets the DTR output line"
		value [logic!]
		return: [logic!]
	][
		if not open? [print "Error: no serial port open"  return false]
		_set-dtr value
	]

	set-rts: func [
		"Sets the RTS output line"
		value [logic!]
		return: [logic!]
	][
		if not open? [print "Error: no serial port open"  return false]
		_set-rts value
	]

	get-cts: func [
		"Returns state of the CTS input line"
		return: [logic!]
	][
		if not open? [return false]
		_get-cts
	]

	get-dsr: func [
		"Returns state of the DSR input line"
		return: [logic!]
	][
		if not open? [return false]
		_get-dsr
	]

	get-cd: func [
		"Returns state of the CD (Carrier Detect) input line"
		return: [logic!]
	][
		if not open? [return false]
		_get-cd
	]

	get-ri: func [
		"Returns state of the RI (Ring Indicator) input line"
		return: [logic!]
	][
		if not open? [return false]
		_get-ri
	]

	flush: func [
		"Flushes serial buffers (both by default)"
		/input  "Flush only input"
		/output "Flush only output"
		return: [logic!]
	][
		if not open? [return false]
		_flush
			either input  [true] [either output [false][true]]
			either output [true] [either input  [false][true]]
	]

	drain: func [
		"Waits for all queued output to be transmitted"
		return: [logic!]
	][
		if not open? [return false]
		_drain
	]

	last-error: func [
		"Returns the last OS error as an object {code message}"
		return: [object!]
		/local err-code
	][
		err-code: _last-error
		make object! [
			code:    err-code
			message: case [
				err-code =  0  ["OK"]
				err-code =  2  ["ENOENT: device not found"]
				err-code =  5  ["EIO: I/O error"]
				err-code =  6  ["ENXIO: no such device or address"]
				err-code = 11  ["EAGAIN: no data available (non-blocking)"]
				err-code = 13  ["EACCES: permission denied (check dialout group)"]
				err-code = 16  ["EBUSY: port in use by another process"]
				err-code = 22  ["EINVAL: invalid argument"]
				err-code = 25  ["ENOTTY: not a serial device"]
				true           [rejoin ["errno " err-code]]
			]
		]
	]
]
