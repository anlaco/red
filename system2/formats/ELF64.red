Red [
	Title:   "Red/System ELF64 format emitter"
	Author:  "Nenad Rakocevic"
	File: 	 %ELF64.red
	Tabs:	 4
	Rights:  "Copyright (C) 2011-2018 Red Foundation. All rights reserved."
	License: "BSD-3 - https://github.com/red/red/blob/master/BSD-3-License.txt"
]

context [
	defs: compose [
		extensions [
			exe %""
			obj %.o
			lib %.a
			dll %.so
		]
	]

	build: func [
		job
		/local base-address ehdr-size code-offset code-size
		ph-size data-offset data-size n-segments machine-word
		cbuf dbuf code-ptr data-ptr entry-offset
	][
		ehdr-size: 64
		ph-size: 56
		n-segments: 4

		base-address: any [job/base-address 400000h]
		code-offset: ehdr-size + (n-segments * ph-size)
		code-size: length? job/sections/code/2
		cbuf: copy job/sections/code/2
		dbuf: copy job/sections/data/2

		code-ptr: base-address + code-offset

		data-offset: code-offset + code-size
		if (data-offset // 4096) <> 0 [
			data-offset: data-offset + (4096 - (data-offset // 4096))
		]
		data-size: length? dbuf
		data-ptr: base-address + data-offset

		machine-word: make-struct [value [integer!]] none
		linker/resolve-symbol-refs job cbuf dbuf code-ptr data-ptr machine-word

		entry-offset: code-offset

		job/buffer: make binary! (data-offset + data-size)

		;; e_ident[16]: magic + class=2(64bit) + data=1(LE) + ver=1 + osabi=3(Linux) + pad=0
		insert tail job/buffer #{7F454C46020101030000000000000000}

		;; e_type=2 EXEC
		append job/buffer to-bin16 2

		;; e_machine=62 EM_X86_64
		append job/buffer to-bin16 62

		;; e_version=1
		append job/buffer to-bin32 1

		;; e_entry (8 bytes, LE)
		append job/buffer to-bin32 (base-address + entry-offset)
		append job/buffer to-bin32 0

		;; e_phoff (8 bytes)
		append job/buffer to-bin32 ehdr-size
		append job/buffer to-bin32 0

		;; e_shoff (8 bytes) = 0, no section headers
		append job/buffer to-bin32 0
		append job/buffer to-bin32 0

		;; e_flags = 0
		append job/buffer to-bin32 0

		;; e_ehsize = 64
		append job/buffer to-bin16 ehdr-size

		;; e_phentsize = 56
		append job/buffer to-bin16 ph-size

		;; e_phnum = 4
		append job/buffer to-bin16 n-segments

		;; e_shentsize = 64
		append job/buffer to-bin16 64

		;; e_shnum = 0
		append job/buffer to-bin16 0

		;; e_shstrndx = 0
		append job/buffer to-bin16 0

		;; -- PT_PHDR --
		append job/buffer to-bin32 6             ;; p_type PT_PHDR
		append job/buffer to-bin32 4             ;; p_flags PF_R
		append job/buffer to-bin32 ehdr-size     ;; p_offset low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 (base-address + ehdr-size)  ;; p_vaddr low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 (base-address + ehdr-size)  ;; p_paddr low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 (n-segments * ph-size)      ;; p_filesz low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 (n-segments * ph-size)      ;; p_memsz low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 8             ;; p_align low
		append job/buffer to-bin32 0

		;; -- PT_LOAD RX --
		append job/buffer to-bin32 1             ;; p_type PT_LOAD
		append job/buffer to-bin32 5             ;; p_flags PF_R|PF_X
		append job/buffer to-bin32 0             ;; p_offset low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 base-address  ;; p_vaddr low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 base-address  ;; p_paddr low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 data-offset   ;; p_filesz low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 data-offset   ;; p_memsz low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 4096          ;; p_align low
		append job/buffer to-bin32 0

		;; -- PT_LOAD RW --
		append job/buffer to-bin32 1             ;; p_type PT_LOAD
		append job/buffer to-bin32 6             ;; p_flags PF_R|PF_W
		append job/buffer to-bin32 data-offset   ;; p_offset low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 (base-address + data-offset)  ;; p_vaddr low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 (base-address + data-offset)  ;; p_paddr low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 data-size     ;; p_filesz low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 data-size     ;; p_memsz low
		append job/buffer to-bin32 0
		append job/buffer to-bin32 4096          ;; p_align low
		append job/buffer to-bin32 0

		;; -- PT_GNU_STACK --
		append job/buffer to-bin32 1685382481    ;; p_type 0x6474E551
		append job/buffer to-bin32 6             ;; p_flags PF_R|PF_W
		append job/buffer to-bin32 0             ;; p_offset=0
		append job/buffer to-bin32 0
		append job/buffer to-bin32 0             ;; p_vaddr=0
		append job/buffer to-bin32 0
		append job/buffer to-bin32 0             ;; p_paddr=0
		append job/buffer to-bin32 0
		append job/buffer to-bin32 0             ;; p_filesz=0
		append job/buffer to-bin32 0
		append job/buffer to-bin32 0             ;; p_memsz=0
		append job/buffer to-bin32 0
		append job/buffer to-bin32 16            ;; p_align
		append job/buffer to-bin32 0

		;; pad to code-offset
		while [(length? job/buffer) < code-offset] [
			append job/buffer #{00}
		]

		;; .text
		append job/buffer cbuf

		;; pad to data-offset
		while [(length? job/buffer) < data-offset] [
			append job/buffer #{00}
		]

		;; .data
		append job/buffer dbuf

		job/buffer
	]
]