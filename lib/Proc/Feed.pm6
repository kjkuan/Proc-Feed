=begin pod

=head1 NAME

`Proc::Feed` provides a couple wrappers for `Proc::Async` that are more
convenient to use than the built-in `run` and `shell` subs. Specifially, these
wrapper subs let you easily feed data to them, and also feed from them to other
callables using the feed operators, `==>` and `<==`.


=head1 SYNOPSIS

=begin code

use Proc::Feed;

# Example
my $src = './mydir';
my $dest = "$src.backup";
proc «cp -r "$src" "$dest"»;


# Example
'hello perl6' \
==> capture('md5sum')
==> split(' ')
==> *.[0]()
==> put('Checksum is: ')
;

# Example
my $text = run {
    pipe «curl http://somewhere.com/text.gz», :bin \
    ==> pipe «gunzip -c», :bin<IN>, :!chomp
    ==> join('')
}
=end code

=end pod

use v6d;

unit module Proc::Feed;

class ProcHandle {
    has Proc::Async $.proc;
    has Promise $.proc-end;
    has Promise $.stdin-writes;
    has Iterable $.stdout-iterable;
    has IO::Handle $.stderr-handle;
    has Bool $.close-stderr-handle;
}

class BrokenPipeline is Exception {

    has $.error of Exception;
    has @.write-errors of Exception;
    has @.procs where Proc|Exception;

    method message { "Proc pipeline failed with errors!" }

    method gist {
        my @errors;

        if $!error {
            @errors.push: "\n--- Block exception: --------";
            @errors.push: $!error.gist;
        }

        for @!procs.kv -> $i, $proc {
            my $error;
            given $proc {
                when Exception {
                    $error = .gist;
                }
                when .?exitcode ≠ 0 {
                    $error = "Process (pipe $i) exited unsuccessfully!\n";
                    $error ~= "Command: {.command.perl}\n";
                    $error ~= "Exit code: {.exitcode}\n";
                }
            }
            if $error {
                @errors.push: "\n--- Proc failed: -----------";
                @errors.push: $error;
            }
            with @!write-errors[$i] {
                @errors.push: "\n------ Failed writing to proc:";
                @errors.push: .gist;
            }
        }
        return @errors.join("\n");
    }
}

multi _proc_impl(Str:D $cmd, |c) {
    _proc_impl(@$cmd, |c);
}

multi _proc_impl(
    @command is copy [$cmd, *@args],
    $input? is raw,

    #| Return an Iterable of data from stdout of the proc.
    Bool :$iter = False,

    #| Capture and return the stdout of the proc as a string.
    Bool :$str = False,

    #| Remove the trailing newline(s) from proc's output.
    #| Only applies when output is not binary.
    Bool :$chomp = True,

    #| Throws an exception if proc or capture failed.
    Bool :$check = True,

    #| Redirects stderr to stdout. Default is False.
    Bool :$merge is copy,

    #| Redirects stderr to a callable, a path in the file system,
    #| or an open file. This option takes precedence over :merge.
    :$stderr where Any|Callable:D|Str:D|IO::Handle:D,

    #| :bin<IN> specifies only the input will be binary blobs;
    #| :bin<OUT> specifies only the output will be binary blobs;
    #| a boolean applies to both input and output of the proc.
    :$bin where Bool:D|'IN'|'OUT' = False,

    Str:D :$enc = 'UTF-8',
    Bool :$translate-nl = True,

    :$cwd = $*CWD,
    Hash() :$env = %*ENV,

    #| If so, run the command through the shell specified;
    #| if True is specified, 'bash' will be used as the shell.
    :$shell is copy where Bool:D|Str:D = False,

    :$scheduler = $*SCHEDULER

) {
    my Bool ($bin-in, $bin-out);
    given $bin {
        when Bool  { $bin-in = $bin-out = $bin }
        when 'IN'  { $bin-in = True }
        when 'OUT' { $bin-out = True }
    }

    if $shell {
        # default the shell to 'bash' when $shell is true.
        $shell = 'bash' when Bool given $shell;
        @command := «"$shell" -c "$cmd" "$shell"», |@args;
    }

    my $proc = Proc::Async.new(
        @command,
        :w($input.DEFINITE),
        :$enc,
        :$translate-nl
    );

    my $chomp-per-line = $str ?? False !! $chomp;

    my (IO::Handle $stderr-handle, Bool $close-stderr-handle);
    with $stderr {
        $merge = False;
        when IO::Handle:D {
            $stderr-handle = $_;
        }
        when Str:D {
            $stderr-handle = open($_, :w);
            $close-stderr-handle = True;
        }
        when Callable:D {
            $proc.stderr.lines(:chomp($chomp-per-line)).tap: $_;
        }
    }
    $proc.bind-stderr($_) with $stderr-handle;

    my $stdout-iterable := do {
        my $d := $chomp-per-line;
        if $merge {
            $bin-out ?? $proc.Supply(:bin).list
                     !! $proc.Supply(:$enc, :$translate-nl).lines(:chomp($d)).list;
        } else {
            $bin-out ?? $proc.stdout(:bin).list
                     !! $proc.stdout.lines(:chomp($d)).list
        }
    } if $iter || $str;


    my $proc-end = $proc.start(:ENV($env), :$cwd);

    my Promise $stdin-writes;
    with $input {
        $stdin-writes = start {
            if $input ~~ Blob {
                await $proc.write($input);
            } else {
                my $method = $bin-in ?? "write" !! "print";
                for $input -> $data {
                    await $proc."$method"($data);
                }
            }
            LEAVE { $proc.close-stdin }
            True;
        }
    }

    my $proc-handle = ProcHandle.new(
        :proc($proc), :$proc-end,
        :$stdin-writes, :$stdout-iterable,
        :$stderr-handle, :$close-stderr-handle
    );


    if $iter || $str {
        if $str {  # it's a capture()
            my $result = $stdout-iterable.join('');

            my $*PIPED-PROCS = Channel.new;
            $*PIPED-PROCS.send: $proc-handle;
            my $proc; {
                $proc = await-procs;
                CATCH {
                    when BrokenPipeline { $proc = .procs[*-1] }
                }
            }
            if $check {
                given $proc {
                    when Proc { .sink if .exitcode ≠ 0 }
                    when Exception { .rethrow }
                }
            }
            return $chomp ?? $result.chomp !! $result;

        } else {
            # it's a pipe() from a run block; let run() do the await-procs.
            $*PIPED-PROCS.send: $proc-handle;
            return $stdout-iterable;
        }
    } else {
        # this case is for the proc() calls
        my $*PIPED-PROCS = Channel.new;
        $*PIPED-PROCS.send: $proc-handle;
        my $proc; {
            $proc = await-procs;
            CATCH {
                when BrokenPipeline { $proc = .procs[*-1] }
            }
        }
        given $proc { when Exception { .rethrow } }
        $proc.sink if $check;
        return $proc;
    }
}



sub await-procs($error?, :$SIGPIPE=False) {
    my @write-errors of Exception;
    my @procs;
    my $i = 0;

    $*PIPED-PROCS.close;
    for $*PIPED-PROCS.list -> (
        :$proc, :$proc-end,
        :$stdin-writes, :$stdout-iterable,
        :$stderr-handle, :$close-stderr-handle
    ) {
        # Signal the child process that we are done with the pipe;
        # Do it in 1s to give the process a chance to exit.
        $proc.ready.then: {
            Promise.in(1).then: { $proc.kill(Signal::SIGPIPE) }
        } if $SIGPIPE;

        with $stdin-writes {
            @write-errors[$i++] = do {
                try await $stdin-writes;
                $! // Nil;
            }
        }

        sink $stdout-iterable.Seq if $stdout-iterable.defined;
        #= needed to ensure $proc-end will be kept.

        @procs.push: (try await $proc-end) // $!;

        $stderr-handle.close if $stderr-handle && $close-stderr-handle;
    }

    if $error ||
       @procs.any ~~ Exception:D|{.?exitcode} ||
       @write-errors.any ~~ Exception:D
    {
        BrokenPipeline.new(
            :error($error // Nil),
            :@procs, :@write-errors
        ).throw;
    }
    return @procs[*-1] if @procs;
}

multi sub run(&block, :$check = True) is export(:DEFAULT, :run) {
    my $*PIPED-PROCS = Channel.new;

    try my $result := block();
    my $error = $!;

    try await-procs($error, :SIGPIPE);
    if $check {
        .rethrow with $!;
        return $result;
    } else {
        return $result, $!;
    }
}

sub proc(
    \command where Str:D|List:D,
    $input? is raw,

    Bool :$check = False,
    :$bin where 'IN' | {! .so} = False,

    :$stderr where Any|Callable:D|Str:D|IO::Handle:D,

    :$cwd = $*CWD,
    Hash() :$env = %*ENV,
    :$shell where Bool:D|Str:D = False,
    :$scheduler = $*SCHEDULER

    --> Proc

) is export(:DEFAULT, :proc) {
    _proc_impl(command, $input, :!str, :!iter,
               :$check,
               :$bin,
               :$stderr,
               :$cwd, :$env,
               :$shell, :$scheduler
    );
}

sub capture(
    \command where Str:D|List:D,
    $input? is raw,

    Bool :$check = True,
    Bool :$chomp = True,
    :$bin where 'IN' | {! .so} = False,

    :$stderr where Any|Callable:D|Str:D|IO::Handle:D,
    Bool :$merge,

    Str:D :$enc = 'UTF-8',
    Bool :$translate-nl = True,
    :$cwd = $*CWD,
    Hash() :$env = %*ENV,
    :$shell where Bool:D|Str:D = False,
    :$scheduler = $*SCHEDULER

    --> Str:D

) is export(:DEFAULT, :capture) {

    _proc_impl(command, $input, :str, :!iter,
               :$check, :$chomp, :$stderr, :$merge,
               :$bin,
               :$enc, :$translate-nl,
               :$cwd, :$env,
               :$shell,
               :$scheduler
    );
}

sub pipe(
    \command where Str:D|List:D,
    $input? is raw,

    Bool :$chomp is copy,

    :$bin where {
        $_ ~~ Bool:D|'IN'|'OUT' and (
            ! ($_ eq 'OUT' || ($_ ~~ Bool && $_))
            || !$chomp
        )
    } = False,

    :$stderr where Any|Callable:D|Str:D|IO::Handle:D,
    Bool :$merge,

    Str:D :$enc = 'UTF-8',
    Bool :$translate-nl = True,
    :$cwd = $*CWD,
    Hash() :$env = %*ENV,
    :$shell where Bool:D|Str:D = False,
    :$scheduler = $*SCHEDULER

    --> List:D

) is export(:DEFAULT, :pipe) {

    $chomp //= do given $bin {
        when 'IN'  { True  }
        when 'OUT' { False }
        default    { !$bin }
    }
    _proc_impl(command, $input, :iter, :!str,
               :$chomp, :$stderr, :$merge, :$bin,
               :$enc, :$translate-nl,
               :$cwd, :$env,
               :$shell,
               :$scheduler
    );
}


sub each(&code, $input? is raw) is export(:each) { code($_) for $input }

multi sub map(Range \range, &code, $input? is raw) is export(:map) {
    gather for $input[range] { take code($_) }
}

sub quote(Str $s --> Str) is export(:quote) { "'{$s.subst("'", Q/'\''/)}'" }
