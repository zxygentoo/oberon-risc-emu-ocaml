MODULE CoreLinker;  (*offline linker for Extended Oberon, derived from EO Modules.Load (NW/AP) and the PO2013 norebo CoreLinker (NW 20.10.2013)*)
  (*Links EO .rsx objects into a flat core image in `buffer`, then serialises it
    for the headless `shim` (LinkSerial) or writes a disk image (LinkDisk).
    Ported from EO Modules.Load: addresses are buffer-relative (the core boots at
    0), the buffer is accessed via base+offset, module descriptors are kept in
    records and copied in at the end, and the module body is NOT run -- a boot
    branch to the top module's body is left at offset 0. See BUILD-EO-IMAGE.md.
    BRING-UP: the boot/MT layout (offset 0 branch, words 4/5/6, MTOrg) mirrors the
    PO2013 norebo core and still needs shim-boot validation for EO.*)
  IMPORT SYSTEM, Files, Texts, Oberon;
  CONST versionkey = 1X; MT = 12; MTOrg = 20H; DescSize = 96; MnLength = 32;
    MOV = 40000000H; BLT = 0F7000000H; BCT = 0E7000000H; U = 20000000H; B = 100000H;
    C4 = 10H; C6 = 40H; C8 = 100H; C10 = 400H; C12 = 1000H; C14 = 4000H; C16 = 10000H;
    C20 = 100000H; C22 = 400000H; C24 = 1000000H; C26 = 4000000H;

  TYPE ModuleName* = ARRAY MnLength OF CHAR;
    Buffer* = ARRAY 63 * 1024 DIV 4 OF INTEGER;

    ImageModDesc = RECORD  (*matches EO Modules.ModDesc, DescSize = 96 bytes*)
        name: ModuleName;
        next: INTEGER;
        key, num, size, refcnt: INTEGER;
        var, str, tdx, prg, imp, cmd, ent, ptr, pvr: INTEGER;  (*addresses, buffer-relative*)
        flags: INTEGER;  (*selected/marked/hidden/sel, packed; 0 in the image*)
        final: INTEGER
      END ;

    Module = POINTER TO ModDesc;
    ModDesc = RECORD next: Module; addr: INTEGER; desc: ImageModDesc END ;

  VAR W: Texts.Writer;
    root: Module;
    AllocPtr*, res*: INTEGER;
    importing*, imported*: ModuleName;

  PROCEDURE ThisFile(name: ARRAY OF CHAR): Files.File;
    VAR i: INTEGER; filename: ModuleName;
  BEGIN i := 0;
    WHILE name[i] # 0X DO filename[i] := name[i]; INC(i) END ;
    (*offline linker: read the renamed `.rsx` objects, so the freshly compiled
      modules being linked don't collide with the live `.rsc` the shim loads to
      run this linker (matches the PO2013 norebo CoreLinker / build-po-image). The
      build renames `.rsc`->`.rsx` around each link call.*)
    filename[i] := "."; filename[i+1] := "r"; filename[i+2] := "s"; filename[i+3] := "x"; filename[i+4] := 0X;
    RETURN Files.Old(filename)
  END ThisFile;

  PROCEDURE error(n: INTEGER; name: ARRAY OF CHAR);
  BEGIN res := n; importing := name
  END error;

  PROCEDURE Check(s: ARRAY OF CHAR);
    VAR i: INTEGER; ch: CHAR;
  BEGIN ch := s[0]; res := 1; i := 0;
    IF (ch >= "A") & (ch <= "Z") OR (ch >= "a") & (ch <= "z") THEN
      REPEAT INC(i); ch := s[i]
      UNTIL ~((ch >= "0") & (ch <= "9") OR (ch >= "A") & (ch <= "Z")
        OR (ch >= "a") & (ch <= "z") OR (ch = ".")) OR (i >= MnLength);
      IF ch = 0X THEN res := 0 END
    END
  END Check;

  PROCEDURE Load(name: ARRAY OF CHAR; base: INTEGER; VAR newmod: Module);
    (*search module in list; if not found load it. base = SYSTEM.ADR(buffer).
      res: 0 ok, 1 bad name, 2 not found, 3 key conflict, 4 corrupted, 7 no space.*)
    VAR mod, impmod: Module;
      i, n, key, impkey, mno, nofimps, size: INTEGER;
      p, adr, inst, pno, vno, disp, dest, offset, w, fixorgP, fixorgD, fixorgT, fixorgM, body: INTEGER;
      ch: CHAR;
      name1, impname: ModuleName;
      F: Files.File; R: Files.Rider;
      import: ARRAY 64 OF Module;
  BEGIN mod := root; res := 0; nofimps := 0;
    WHILE (mod # NIL) & (name # mod.desc.name) DO mod := mod.next END ;
    IF mod = NIL THEN (*load*)
      Check(name);
      IF res = 0 THEN F := ThisFile(name) ELSE F := NIL END ;
      IF F # NIL THEN
        Files.Set(R, F, 0); Files.ReadString(R, name1); Files.ReadInt(R, key); Files.Read(R, ch);
        Files.ReadInt(R, size); importing := name1;
        IF ch = versionkey THEN
          Files.ReadString(R, impname);
          WHILE (impname[0] # 0X) & (res = 0) DO
            Files.ReadInt(R, impkey);
            Load(impname, base, impmod); import[nofimps] := impmod; importing := name1;
            IF res = 0 THEN
              IF impmod.desc.key = impkey THEN INC(impmod.desc.refcnt); INC(nofimps)
              ELSE error(3, name1); imported := impname
              END
            END ;
            Files.ReadString(R, impname)
          END
        ELSE error(4, name1)
        END
      ELSE error(2, name)
      END ;
      IF res = 0 THEN (*allocate and link*)
        INC(size, DescSize);
        IF AllocPtr + size < LEN(name1) * 0 + 63 * 1024 THEN
          NEW(mod); mod.next := root; root := mod; mod.addr := AllocPtr;
          mod.desc.size := size;
          IF mod.next = NIL THEN mod.desc.num := 1; mod.desc.next := 0
          ELSE mod.desc.num := mod.next.desc.num + 1; mod.desc.next := mod.next.addr
          END ;
          AllocPtr := (AllocPtr + size + 3) DIV 4 * 4
        ELSE error(7, name1)
        END
      END ;
      IF res = 0 THEN (*read sections into buffer at base+p, addresses relative*)
        p := mod.addr + DescSize;
        i := 0; WHILE name[i] # 0X DO mod.desc.name[i] := name[i]; INC(i) END ;
        WHILE i < MnLength DO mod.desc.name[i] := 0X; INC(i) END ;
        mod.desc.key := key; mod.desc.refcnt := 0; mod.desc.flags := 0;
        mod.desc.var := p; Files.ReadInt(R, n);
        WHILE n > 0 DO SYSTEM.PUT(base + p, 0); INC(p, 4); DEC(n, 4) END ;  (*variable space*)
        mod.desc.str := p; Files.ReadInt(R, n);
        WHILE n > 0 DO Files.Read(R, ch); SYSTEM.PUT(base + p, ch); INC(p); DEC(n) END ;  (*strings*)
        mod.desc.tdx := p; Files.ReadInt(R, n);
        WHILE n > 0 DO Files.ReadInt(R, w); SYSTEM.PUT(base + p, w); INC(p, 4); DEC(n, 4) END ;  (*type descriptors*)
        mod.desc.prg := p; Files.ReadInt(R, n);
        WHILE n > 0 DO Files.ReadInt(R, w); SYSTEM.PUT(base + p, w); INC(p, 4); DEC(n) END ;  (*program code*)
        mod.desc.imp := p; i := 0;
        WHILE i < nofimps DO SYSTEM.PUT(base + p, import[i].addr); INC(p, 4); INC(i) END ;  (*imports*)
        mod.desc.cmd := p; Files.Read(R, ch);
        WHILE ch # 0X DO  (*commands: name, 0X, pad, int*)
          REPEAT SYSTEM.PUT(base + p, ch); INC(p); Files.Read(R, ch) UNTIL ch = 0X;
          REPEAT SYSTEM.PUT(base + p, 0X); INC(p) UNTIL p MOD 4 = 0;
          Files.ReadInt(R, n); SYSTEM.PUT(base + p, n); INC(p, 4); Files.Read(R, ch)
        END ;
        REPEAT SYSTEM.PUT(base + p, 0X); INC(p) UNTIL p MOD 4 = 0;
        mod.desc.ent := p; Files.ReadInt(R, n);
        WHILE n > 0 DO Files.ReadInt(R, w); SYSTEM.PUT(base + p, w); INC(p, 4); DEC(n) END ;  (*entries*)
        mod.desc.ptr := p; Files.ReadInt(R, w);
        WHILE w >= 0 DO SYSTEM.PUT(base + p, mod.desc.var + w); INC(p, 4); Files.ReadInt(R, w) END ;  (*pointer refs*)
        SYSTEM.PUT(base + p, 0); INC(p, 4);
        mod.desc.pvr := p; Files.ReadInt(R, w);
        WHILE w >= 0 DO SYSTEM.PUT(base + p, mod.desc.var + w); INC(p, 4); Files.ReadInt(R, w) END ;  (*proc-var refs*)
        SYSTEM.PUT(base + p, 0); INC(p, 4);
        Files.ReadInt(R, fixorgP); Files.ReadInt(R, fixorgD);
        Files.ReadInt(R, fixorgT); Files.ReadInt(R, fixorgM);
        Files.ReadInt(R, w); body := mod.desc.prg + w;
        Files.ReadInt(R, w);
        IF w >= 0 THEN mod.desc.final := mod.desc.prg + w ELSE mod.desc.final := 0 END ;
        Files.Read(R, ch);
        IF ch # "O" THEN mod := NIL; error(4, name) END
      END ;
      IF res = 0 THEN (*fixup of BL*)
        adr := mod.desc.prg + fixorgP * 4;
        WHILE adr # mod.desc.prg DO
          SYSTEM.GET(base + adr, inst);
          mno := inst DIV C22 MOD C6; pno := inst DIV C14 MOD C8; disp := inst MOD C14;
          impmod := import[mno-1];
          SYSTEM.GET(base + impmod.desc.ent + pno * 4, dest); dest := dest + impmod.desc.prg;
          offset := (dest - adr - 4) DIV 4;
          SYSTEM.PUT(base + adr, BLT + offset MOD C24);
          adr := adr - disp * 4
        END ;
        (*fixup of MOV/IOR/LDR/STR*)
        adr := mod.desc.prg + fixorgD * 4;
        WHILE adr # mod.desc.prg DO
          SYSTEM.GET(base + adr, inst);
          pno := inst DIV C26 MOD C4; mno := inst DIV C20 MOD C6; disp := inst MOD C12;
          IF mno = 0 THEN  (*global*)
            offset := inst DIV C12 MOD C8 * C16;
            SYSTEM.GET(base + adr + 4, inst);
            INC(offset, mod.desc.var + inst MOD C16)
          ELSE  (*import*)
            impmod := import[mno-1];
            SYSTEM.GET(base + adr + 4, inst); vno := inst MOD C8;
            SYSTEM.GET(base + impmod.desc.ent + vno * 4, offset);
            IF ODD(inst DIV C8) THEN INC(offset, impmod.desc.prg) ELSE INC(offset, impmod.desc.var) END
          END ;
          SYSTEM.PUT(base + adr, MOV + U + B + pno * C24 + offset DIV C16);
          SYSTEM.PUT(base + adr + 4, inst DIV C16 * C16 + offset MOD C16);
          adr := adr - disp * 4
        END ;
        (*fixup of type descriptors*)
        adr := mod.desc.tdx + fixorgT * 4;
        WHILE adr # mod.desc.tdx DO
          SYSTEM.GET(base + adr, inst);
          mno := inst DIV C24 MOD C6; vno := inst DIV C12 MOD C12; disp := inst MOD C12;
          IF mno = 0 THEN inst := mod.desc.tdx + vno
          ELSE impmod := import[mno-1];
            SYSTEM.GET(base + impmod.desc.ent + vno * 4, offset); inst := impmod.desc.var + offset
          END ;
          SYSTEM.PUT(base + adr, inst); adr := adr - disp * 4
        END ;
        (*fixup of method tables*)
        adr := mod.desc.tdx + fixorgM * 4;
        WHILE adr # mod.desc.tdx DO
          SYSTEM.GET(base + adr, inst);
          mno := inst DIV C26 MOD C6; vno := inst DIV C10 MOD C16; disp := inst MOD C10;
          IF mno = 0 THEN inst := mod.desc.prg + vno
          ELSE impmod := import[mno-1];
            SYSTEM.GET(base + impmod.desc.ent + vno * 4, offset); inst := impmod.desc.prg + offset
          END ;
          SYSTEM.PUT(base + adr, inst); adr := adr - disp * 4
        END ;
        SYSTEM.PUT(base + MTOrg + mod.desc.num * 4, mod.addr);  (*module table entry*)
        SYSTEM.PUT(base, BCT + body DIV 4 - 1)  (*boot branch to (top) module body*)
      ELSIF res = 3 THEN importing := name;
        WHILE nofimps > 0 DO DEC(nofimps); DEC(import[nofimps].desc.refcnt) END
      END
    END ;
    newmod := mod
  END Load;

  PROCEDURE Link(name: ARRAY OF CHAR; VAR buffer: ARRAY OF INTEGER);
    VAR mod, m: Module; base, n: INTEGER;
  BEGIN
    FOR n := 0 TO LEN(buffer) - 1 DO buffer[n] := 0 END ;
    AllocPtr := 100H; root := NIL; res := 0;
    base := SYSTEM.ADR(buffer);
    Load(name, base, mod);
    IF res = 0 THEN
      buffer[4] := AllocPtr; buffer[5] := mod.addr; buffer[6] := 40000H;
      m := root;  (*copy module descriptors into the image*)
      WHILE m # NIL DO
        SYSTEM.COPY(SYSTEM.ADR(m.desc), base + m.addr, DescSize DIV 4); m := m.next
      END
    END
  END Link;

  PROCEDURE LinkSerialImage*(modname, corename: ARRAY OF CHAR);
    VAR buffer: Buffer; F: Files.File; R: Files.Rider; i: INTEGER;
  BEGIN Link(modname, buffer);
    IF res = 0 THEN
      F := Files.New(corename); Files.Set(R, F, 0);
      Files.WriteInt(R, AllocPtr); Files.WriteInt(R, 0);
      FOR i := 0 TO AllocPtr DIV 4 - 1 DO Files.WriteInt(R, buffer[i]) END ;
      Files.WriteInt(R, 0); Files.Register(F)
    END
  END LinkSerialImage;

  PROCEDURE LinkDiskImage*(modname, corename: ARRAY OF CHAR);
    VAR buffer: Buffer; F: Files.File; R: Files.Rider; i: INTEGER;
  BEGIN Link(modname, buffer);
    IF res = 0 THEN
      F := Files.New(corename); Files.Set(R, F, 0);
      Files.WriteInt(R, 9B1EA38DH); FOR i := 4 TO 1023 DO Files.WriteByte(R, 0) END ;
      FOR i := 0 TO AllocPtr DIV 4 - 1 DO Files.WriteInt(R, buffer[i]) END ;
      Files.Register(F)
    END
  END LinkDiskImage;

  PROCEDURE LinkCommand(linkProc: PROCEDURE(modname, corename: ARRAY OF CHAR));
    VAR S: Texts.Scanner; modname, corename: ModuleName;
  BEGIN Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
    IF S.class = Texts.Name THEN modname := S.s; Texts.Scan(S);
      IF S.class = Texts.Name THEN corename := S.s;
        linkProc(modname, corename);
        Texts.WriteString(W, "Linking "); Texts.WriteString(W, corename);
        IF res = 0 THEN Texts.WriteInt(W, AllocPtr, 6)
        ELSE Texts.WriteString(W, "  error "); Texts.WriteInt(W, res, 0)
        END ;
        Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
      END
    END
  END LinkCommand;

  PROCEDURE LinkSerial*;
  BEGIN LinkCommand(LinkSerialImage)
  END LinkSerial;

  PROCEDURE LinkDisk*;
  BEGIN LinkCommand(LinkDiskImage)
  END LinkDisk;

BEGIN Texts.OpenWriter(W)
END CoreLinker.
