MODULE AgentProtocol;  (*the oat wire protocol, shared verbatim by both variants.
  Owns everything that touches the serial line: byte layer, frame parsing,
  the PUT/GET/EDIT handlers, CALL framing, and the poll task. Variant
  semantics enter through exactly one hook: an Executor that runs an already
  parsed command and returns a status. AgentTool (per variant) provides it
  via Start and owns the named commands oat invokes.*)
  IMPORT SYSTEM, Files, Texts, Oberon;

  CONST
    data = -56; stat = -52;            (*RS232 MMIO; status bit0 = rx, bit1 = tx*)
    sync = 0A5H; rsync = 05AH;         (*request / response frame start*)
    opPut = 1; opGet = 2; opCall = 3; opEdit = 4;
    stOk* = 0; stNotFound* = 1; stTrapped = 2; stError* = 3; stNoMatch = 4; stNotUnique = 5;
    editLim = 1024;                    (*max OLD length; oat falls back to GET+PUT beyond -- keep in sync with protocol.rs EDIT_OLD_LIMIT*)
    recLim = 4000000;                  (*Rec busy-wait cap (~1s @25MHz): a lost byte aborts the frame instead of hanging the whole Oberon loop*)
    maxPut = 10000H;                   (*64 KiB: PUT receive-buffer size and length cap (a larger PUT, or a corrupt count, gets stError)*)

  TYPE
    Executor* = PROCEDURE (cmd: ARRAY OF CHAR; par: Texts.Text): INTEGER;

  VAR
    T: Oberon.Task;
    WT: Oberon.Task;                   (*watchdog: reinstalls T after a trap removed it*)
    exec: Executor;                    (*variant command executor; set by Start before the task ever runs*)
    inFlight: BOOLEAN;                 (*a command was running when a trap unwound the task*)
    flightBeg: INTEGER;                (*Oberon.Log.len at command start; the delta carries the TRAP line*)
    rxOk: BOOLEAN;                     (*cleared by Rec on a receive timeout; short-circuits the rest of the frame*)
    EW: Texts.Writer;                  (*buffers EDIT's NEW text*)
    PW: Texts.Writer;                  (*builds CALL's par text*)
    par: Texts.Text;
    name, cmd: ARRAY 64 OF CHAR;
    M: INTEGER;                        (*DoEdit pattern length; global because Forward can't see DoEdit's locals*)
    pat, win: ARRAY editLim OF CHAR;   (*DoEdit pattern + sliding match window*)
    dis: ARRAY 256 OF INTEGER;         (*Boyer-Moore displacement table*)
    pbuf: ARRAY maxPut OF BYTE;        (*DoPut payload buffer: receive the whole frame, then write*)

  (* --- serial byte layer (PCLink1's Rec/Send, status-gated) --- *)

  PROCEDURE Rec(VAR x: BYTE);   (*bounded: spin up to recLim for a byte. On timeout, clear
    rxOk and short-circuit -- once rxOk is FALSE every later Rec in the frame returns at once,
    so a lost byte aborts the frame (handlers check rxOk) instead of busy-waiting forever and
    freezing the Oberon loop. The single-byte RS232 register has no flow control, so this is
    the only line that can hang on a real UART.*)
    VAR n: INTEGER;
  BEGIN
    IF rxOk THEN n := 0;
      WHILE ~SYSTEM.BIT(stat, 0) & (n < recLim) DO INC(n) END ;
      IF SYSTEM.BIT(stat, 0) THEN SYSTEM.GET(data, x) ELSE rxOk := FALSE END
    END
  END Rec;

  PROCEDURE Send(x: BYTE);
  BEGIN REPEAT UNTIL SYSTEM.BIT(stat, 1); SYSTEM.PUT(data, x)
  END Send;

  PROCEDURE RecInt(VAR n: INTEGER);    (*4 bytes, little-endian*)
    VAR a, b, c, d: BYTE;
  BEGIN Rec(a); Rec(b); Rec(c); Rec(d);
    n := a + b*100H + c*10000H + d*1000000H
  END RecInt;

  PROCEDURE SendInt(n: INTEGER);
  BEGIN Send(n MOD 100H); Send(n DIV 100H MOD 100H);
    Send(n DIV 10000H MOD 100H); Send(n DIV 1000000H MOD 100H)
  END SendInt;

  PROCEDURE RecName(VAR s: ARRAY OF CHAR);   (*1-byte length prefix, then the chars*)
    VAR n, i: INTEGER; x: BYTE;
  BEGIN Rec(x); n := x; i := 0;
    WHILE i < n DO Rec(x); s[i] := CHR(x); INC(i) END;
    s[i] := 0X
  END RecName;

  PROCEDURE Reply(status: INTEGER);   (*zero-payload response; closes any in-flight window*)
  BEGIN inFlight := FALSE;
    Send(rsync); Send(status); SendInt(0)
  END Reply;

  PROCEDURE ReplyLog(status, beg: INTEGER);   (*response carrying the Log delta since beg*)
    VAR lim: INTEGER; ch: CHAR; R: Texts.Reader;
  BEGIN inFlight := FALSE; lim := Oberon.Log.len;
    Send(rsync); Send(status); SendInt(lim - beg);
    Texts.OpenReader(R, Oberon.Log, beg);
    WHILE Texts.Pos(R) < lim DO Texts.Read(R, ch); Send(ORD(ch)) END
  END ReplyLog;

  (* --- request handlers --- *)

  PROCEDURE DoPut;   (*Drain the whole payload into RAM with a tight Rec loop, THEN write the
    file. Files.WriteByte hits Disk.PutSector (a slow SD/SPI write) at every sector boundary
    -- the first at byte SectorSize-HeaderSize = 1024-352 = 672 -- and doing that inside the
    receive loop stalls long enough to overrun the one-byte RS232 register and drop the next
    byte. So receive first (no disk I/O between bytes), write after the wire is drained.*)
    VAR F: Files.File; R: Files.Rider; len, i: INTEGER;
  BEGIN RecName(name); RecInt(len);
    IF rxOk & (len >= 0) & (len <= maxPut) THEN
      i := 0;
      WHILE i < len DO Rec(pbuf[i]); INC(i) END ;        (*receive: RAM only, never overruns*)
      IF rxOk THEN                                       (*whole frame arrived -> commit*)
        F := Files.New(name); Files.Set(R, F, 0); i := 0;
        WHILE i < len DO Files.WriteByte(R, pbuf[i]); INC(i) END ;
        Files.Register(F); Reply(stOk)
      END                                                (*else: lost byte -> abort, no reply*)
    ELSIF rxOk THEN Reply(stError)                       (*frame intact but length out of range*)
    END
  END DoPut;

  PROCEDURE DoGet;
    VAR F: Files.File; R: Files.Rider; len, i: INTEGER; x: BYTE;
  BEGIN RecName(name);
    IF rxOk THEN                       (*name fully received*)
      F := Files.Old(name);
      IF F = NIL THEN
        Reply(stNotFound)
      ELSE
        len := Files.Length(F); Files.Set(R, F, 0);
        Send(rsync); Send(stOk); SendInt(len); i := 0;
        WHILE i < len DO Files.ReadByte(R, x); Send(x); INC(i) END
      END
    END
  END DoGet;

  PROCEDURE DoCall;   (*parse the frame, run the variant's executor, frame the
    Log delta written while it ran as the response. The in-flight window marks
    the stretch where a trap unwinds us before any response byte went out --
    Recover (next task tick) can then still complete the exchange.*)
    VAR len, i, status: INTEGER; x: BYTE;
  BEGIN RecName(cmd); RecInt(len);
    NEW(par); Texts.Open(par, ""); i := 0;
    WHILE i < len DO Rec(x); Texts.Write(PW, CHR(x)); INC(i) END;
    IF rxOk THEN                        (*whole frame arrived -> run the command*)
      Texts.Append(par, PW.buf);
      flightBeg := Oberon.Log.len; inFlight := TRUE;
      IF exec # NIL THEN status := exec(cmd, par) ELSE status := stError END;
      ReplyLog(status, flightBeg)
    ELSE Texts.OpenWriter(PW)           (*lost byte -> drop the partial par, abort, no reply*)
    END
  END DoCall;

  (*DoEdit: replace a unique occurrence of OLD by NEW inside a file, on the
    device, through the Texts piece list -- unchanged content is never copied
    until Texts.Close streams the result out. The scan is Edit.Search's
    Boyer-Moore, restated to count every non-overlapping match instead of
    stopping at the first.*)

  PROCEDURE Forward(n: INTEGER; VAR R: Texts.Reader);   (*slide win left by n, refill from R*)
    VAR m, j: INTEGER;
  BEGIN m := M - n; j := 0;
    WHILE j < m DO win[j] := win[n + j]; INC(j) END;
    WHILE j < M DO Texts.Read(R, win[j]); INC(j) END
  END Forward;

  PROCEDURE DoEdit;
    VAR T: Texts.Text; R: Texts.Reader; B: Texts.Buffer;
      oldLen, newLen, i, j, n, pos, count, first: INTEGER;
      x: BYTE; done: BOOLEAN;
  BEGIN RecName(name);
    RecInt(oldLen); i := 0;                              (*OLD -> pat; excess drained*)
    WHILE i < oldLen DO Rec(x);
      IF i < editLim THEN pat[i] := CHR(x) END;
      INC(i)
    END;
    RecInt(newLen); i := 0;                              (*NEW -> EW.buf, unbounded*)
    WHILE i < newLen DO Rec(x); Texts.Write(EW, CHR(x)); INC(i) END;
    IF ~rxOk THEN Texts.OpenWriter(EW)                   (*lost byte -> drop NEW, abort, no reply*)
    ELSE
      (*frame consumed -- safe to answer, and to recover from a trap. Only this branch arms
        inFlight: the oldLen / Files.Old guards just Reply, but the edit below can trap. rxOk
        is checked before committing, matching DoPut/DoCall.*)
      flightBeg := Oberon.Log.len; inFlight := TRUE;
      IF (oldLen <= 0) OR (oldLen > editLim) THEN
        Texts.OpenWriter(EW);                            (*drop buffered NEW*)
        Reply(stError)
      ELSIF Files.Old(name) = NIL THEN
        Texts.OpenWriter(EW);
        Reply(stNotFound)
      ELSE
        NEW(T); Texts.Open(T, name);                     (*plain or formatted file*)
        M := oldLen; count := 0; first := -1;
        IF M <= T.len THEN
          j := 0; WHILE j < 256 DO dis[j] := M; INC(j) END;
          j := 0; WHILE j < M - 1 DO dis[ORD(pat[j])] := M - 1 - j; INC(j) END;
          Texts.OpenReader(R, T, 0);
          Forward(M, R); pos := M; done := FALSE;
          REPEAT
            j := M;
            REPEAT DEC(j) UNTIL (j < 0) OR (win[j] # pat[j]);
            IF j < 0 THEN INC(count);                    (*match ends at pos*)
              IF first < 0 THEN first := pos - M END;
              n := M                                     (*non-overlapping, like the host counts*)
            ELSE n := dis[ORD(win[M - 1])]
            END;
            IF pos + n <= T.len THEN Forward(n, R); pos := pos + n ELSE done := TRUE END
          UNTIL done
        END;
        IF count = 0 THEN
          Texts.OpenWriter(EW);
          Reply(stNoMatch)
        ELSIF count > 1 THEN
          Texts.OpenWriter(EW);
          inFlight := FALSE;
          Send(rsync); Send(stNotUnique); SendInt(4); SendInt(count)
        ELSE
          NEW(B); Texts.OpenBuf(B);
          Texts.Delete(T, first, first + M, B);          (*B receives the OLD chars, discarded*)
          Texts.Insert(T, first, EW.buf);                (*consumes and resets EW.buf*)
          Texts.Close(T, name);                          (*atomic: Files.Register swaps the dir entry*)
          Reply(stOk)
        END
      END
    END
  END DoEdit;

  (*Trap survival. Oberon.Reset removes the task whose handler trapped (the
    *active* task), which would silence the wire for good. Two pieces fix it:
    Watch, a one-line watchdog task that reinstalls T (Oberon.Install is a
    no-op while T is alive); and the in-flight flag, which lets the revived
    task notice it was unwound mid-command and complete the exchange with
    stTrapped -- the Log delta carries the trap handler's "pos .. TRAP .." line.*)

  PROCEDURE Recover;   (*finish the exchange a trap interrupted*)
  BEGIN
    Texts.OpenWriter(PW); Texts.OpenWriter(EW);          (*drop half-built buffers*)
    ReplyLog(stTrapped, flightBeg)
  END Recover;

  PROCEDURE Task;   (*one poll tick; Oberon.Loop calls this when installed*)
    VAR op, b: BYTE;
  BEGIN
    IF inFlight THEN Recover END ;
    IF SYSTEM.BIT(stat, 0) THEN
      rxOk := TRUE;                    (*fresh frame; Rec clears this on a mid-frame timeout*)
      Rec(b);                          (*sync; a non-sync byte is dropped to resync*)
      IF rxOk & (b = sync) THEN
        Rec(op);
        IF rxOk THEN
          IF op = opPut THEN DoPut
          ELSIF op = opGet THEN DoGet
          ELSIF op = opCall THEN DoCall
          ELSIF op = opEdit THEN DoEdit
          END
        END
      END
    END
  END Task;

  PROCEDURE Watch;   (*watchdog tick: bring the wire task back if a trap removed it*)
  BEGIN Oberon.Install(T)
  END Watch;

  PROCEDURE Start*(e: Executor);   (*install the variant's executor, then the tasks*)
  BEGIN exec := e;
    IF T = NIL THEN
      T := Oberon.NewTask(Task, 0); Oberon.Install(T);
      WT := Oberon.NewTask(Watch, 0); Oberon.Install(WT)
    END
  END Start;

BEGIN rxOk := TRUE; Texts.OpenWriter(EW); Texts.OpenWriter(PW)
END AgentProtocol.
