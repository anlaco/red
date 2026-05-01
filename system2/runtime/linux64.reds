Red/System [
	Title:   "Red/System Linux x64 runtime"
	Author:  "Nenad Rakocevic"
	File: 	 %linux64.reds
	Tabs:	 4
	Rights:  "Copyright (C) 2011-2018 Red Foundation. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
]

#define OS_TYPE		2

#syscall [
	write: 1 [
		fd		[integer!]
		buffer	[c-string!]
		count	[integer!]
		return: [integer!]
	]
]

#if use-natives? = yes [
	#syscall [
		quit: 60 [
			status	[integer!]
		]
	]
]

;-------------------------------------------
;-- Retrieve command-line information from stack
;-------------------------------------------
#if type = 'exe [
	#either use-natives? = yes [
		system/args-count:	pop
		system/args-list:	as str-array! system/stack/top
		system/env-vars:	system/args-list + system/args-count + 1
	][
		system/args-count:	***__argc
		system/args-list:	as str-array! ***__argv
		system/env-vars:	system/args-list + system/args-count + 1
	]
]

#include %linux-sigaction.reds
#include %POSIX.reds
