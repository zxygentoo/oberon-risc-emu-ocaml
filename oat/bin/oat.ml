(** oat — oberon-agent-tool — stateless CLI driver for [AgentTool.Mod] on a live
    Project Oberon or Extended Oberon system, over an emulator FIFO pair or a real
    serial device. See [skill/oberon-agent/] for the agent-side rules. Everything
    lives in {!Oat.Cli}; this file is only the entry point. *)

let () = Oat.Cli.main ()
