MODULE Disk;	(*NW/PR  11.4.86 / 27.12.95 / 4.2.2014 / AP 1.1.22 Extended Oberon*)
	(*Headless host adaptation for the `shim` build runtime. Extended Oberon's Disk
	  with the SD-card SPI driver removed: the sector-bitmap allocator is EO's,
	  verbatim, but GetSector/PutSector are unreachable on the compile + ORL.Link
	  path (the build's host-backed Files bypass the sector layer, and ORL.Link
	  writes Modules.bin through Files), so they abort if ever called. Host-backed
	  sectors for ORL.Load come later -- see crates/host-tools/BUILD-EO-IMAGE.md.*)
	IMPORT SYSTEM, Norebo;
	CONST SectorLength* = 1024;
		mapsize = 10000H; (*1K sectors, 64MB*)

	TYPE Sector* = ARRAY SectorLength OF BYTE;

	VAR NofSectors*: INTEGER;
		sectorMap: ARRAY mapsize DIV 32 OF SET;

	PROCEDURE InitSecMap*;
		VAR i: INTEGER;
	BEGIN NofSectors := 0;
		FOR i := 0 TO 5 DO sectorMap[i] := {0 .. 31} END ;         	(*mark blocks 0-191 (=6*32 = 192 blocks) as allocated*)
		FOR i := 6 TO mapsize DIV 32 - 1 DO sectorMap[i] := {} END 	(*mark blocks 192-65536 (=64K-192 blocks) as unallocated*)
	END InitSecMap;

	PROCEDURE MarkSector*(sec: INTEGER);
	BEGIN sec := sec DIV 29; ASSERT(SYSTEM.H(0) = 0);
		INCL(sectorMap[sec DIV 32], sec MOD 32); INC(NofSectors)
	END MarkSector;

	PROCEDURE FreeSector*(sec: INTEGER);
	BEGIN sec := sec DIV 29; ASSERT(SYSTEM.H(0) = 0);
		EXCL(sectorMap[sec DIV 32], sec MOD 32); DEC(NofSectors)
	END FreeSector;

	PROCEDURE AllocSector*(hint: INTEGER; VAR sec: INTEGER);
		VAR s: INTEGER;
	BEGIN (*find free sector, starting after hint*)
		hint := hint DIV 29; ASSERT(SYSTEM.H(0) = 0); s := hint;
		REPEAT INC(s);
			IF s = mapsize THEN s := 1 END ;
		UNTIL ~(s MOD 32 IN sectorMap[s DIV 32]);
		INCL(sectorMap[s DIV 32], s MOD 32); INC(NofSectors); sec := s * 29
	END AllocSector;

	(*Sector I/O is unsupported in the headless build (see the module comment).
	  Abort loudly rather than touch SD hardware the shim does not model.*)
	PROCEDURE GetSector*(src: INTEGER; VAR dst: Sector);
	BEGIN Norebo.Halt(101)
	END GetSector;

	PROCEDURE PutSector*(dst: INTEGER; VAR src: Sector);
	BEGIN Norebo.Halt(101)
	END PutSector;

	PROCEDURE Init*;
	BEGIN InitSecMap
	END Init;

END Disk.
