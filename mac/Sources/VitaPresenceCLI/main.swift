import Darwin

// Line-buffer standard output so status lines appear immediately even when piped, for example into `tee`.
setvbuf(stdout, nil, _IOLBF, 0)
// Ctrl-C also ends a `tee` reading the output. Writing to it must then fail quietly (EPIPE) instead of
// killing the process before it has cleared the presence and exited with status 0.
signal(SIGPIPE, SIG_IGN)
exit(await CommandLineTool.run(arguments: Array(CommandLine.arguments.dropFirst())))
