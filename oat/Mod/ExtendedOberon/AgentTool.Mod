MODULE AgentTool;  (*serial agent server for the oberon-agent skill -- Extended Oberon target.
  The wire protocol lives in AgentProtocol; this module never touches a serial
  byte. It provides the Executor (how this variant runs a command) and the
  named commands, which oat invokes under the AgentTool name.*)
  IMPORT Disk, FileDir, Modules, Display, Texts, Oberon, System, AgentProtocol;
  (*AgentProtocol last: its interface references Texts types, and ORB requires
    referenced modules to be imported before the module that uses them*)

  VAR
    W: Texts.Writer;                   (*Log/output writer for the commands*)
    parF: Display.Frame;               (*dummy frame for Oberon.SetPar; cmd/pos start at 0*)
    pfx: ARRAY 32 OF CHAR;
    ownLog: Texts.Text;                (*installed as Oberon.Log if none exists yet at boot*)

  (* --- the variant's command executor (CALL semantics) --- *)

  PROCEDURE Exec(cmd: ARRAY OF CHAR; par: Texts.Text): INTEGER;
    VAR res, status: INTEGER;
  BEGIN
    Oberon.SetPar(parF, par, 0, 0, 0);     (*F, T, cmd, pos, res -- params start at 0*)
    Modules.Call(cmd, res);
    IF res = Modules.noerr THEN status := AgentProtocol.stOk
    ELSIF (res = Modules.nofile) OR (res = Modules.nocmd)
       OR (res = Modules.badcmd) OR (res = Modules.nomod) THEN status := AgentProtocol.stNotFound
    ELSE status := AgentProtocol.stError
    END;
    RETURN status
  END Exec;

  (* --- introspection commands (write to Oberon.Log, unlike viewer-coupled originals) --- *)

  PROCEDURE Version*;   (*echo System.Version to the Log; oat `check` parses it.*)
  BEGIN Texts.WriteString(W, System.Version); Texts.WriteLn(W);
    Texts.Append(Oberon.Log, W.buf)
  END Version;

  PROCEDURE Prefixed(p, s: ARRAY OF CHAR): BOOLEAN;
    VAR i: INTEGER;
  BEGIN i := 0;
    WHILE (p[i] # 0X) & (p[i] = s[i]) DO INC(i) END;
    RETURN p[i] = 0X
  END Prefixed;

  PROCEDURE FileEntry(fn: FileDir.FileName; sec: INTEGER; VAR continue: BOOLEAN);
    VAR hp: FileDir.FileHeader;
  BEGIN
    IF Prefixed(pfx, fn) THEN
      Disk.GetSector(sec, hp);
      Texts.WriteString(W, fn); Texts.Write(W, 9X);
      Texts.WriteInt(W, hp.aleng*FileDir.SectorSize + hp.bleng - FileDir.HeaderSize, 1);
      Texts.Write(W, 9X); Texts.WriteClock(W, hp.date); Texts.WriteLn(W)
    END;
    continue := TRUE
  END FileEntry;

  PROCEDURE ListFiles*;
    VAR S: Texts.Scanner;
  BEGIN
    Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
    IF S.class = Texts.Name THEN pfx := S.s ELSE pfx[0] := 0X END;
    FileDir.Enumerate(pfx, FileEntry);
    Texts.Append(Oberon.Log, W.buf)
  END ListFiles;

  PROCEDURE ListModules*;   (*name <TAB> refcnt <TAB> code-addr (EO 'prg')*)
    VAR m: Modules.Module;
  BEGIN m := Modules.root;
    WHILE m # NIL DO
      IF m.name[0] # 0X THEN
        Texts.WriteString(W, m.name); Texts.Write(W, 9X);
        Texts.WriteInt(W, m.refcnt, 1); Texts.Write(W, 9X);
        Texts.WriteHex(W, m.prg); Texts.WriteLn(W)
      END;
      m := m.next
    END;
    Texts.Append(Oberon.Log, W.buf)
  END ListModules;

  PROCEDURE Load*;
    VAR S: Texts.Scanner; m: Modules.Module;
  BEGIN
    Texts.OpenScanner(S, Oberon.Par.text, Oberon.Par.pos); Texts.Scan(S);
    IF S.class = Texts.Name THEN
      Modules.Load(S.s, m);
      IF Modules.res = Modules.noerr THEN
        Texts.WriteString(W, "loaded "); Texts.WriteString(W, S.s)
      ELSE
        Texts.WriteString(W, "load failed "); Texts.WriteString(W, S.s);
        Texts.WriteString(W, " res="); Texts.WriteInt(W, Modules.res, 1)
      END;
      Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
    END
  END Load;

BEGIN Texts.OpenWriter(W); NEW(parF);
  IF Oberon.Log = NIL THEN NEW(ownLog); Texts.Open(ownLog, ""); Oberon.OpenLog(ownLog) END;
  AgentProtocol.Start(Exec);
  Texts.WriteString(W, "AgentTool installed"); Texts.WriteLn(W); Texts.Append(Oberon.Log, W.buf)
END AgentTool.
