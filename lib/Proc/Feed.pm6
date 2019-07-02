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
    pipe(«curl http://somewhere.com/text.gz», :bin) \
    ==> pipe(«gunzip -c», :bin<IN>, :!chomp)
    ==> join('')
}
=end code

=end pod

use v6;

unit module Proc::Feed;

multi _proc_impl(Str:D $cmd, |c) {
    _proc_impl(@$cmd, |c);
}

#| This proc does something
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

    #| When :str, return a Failure if the proc failed.
    #| Default is True.
    Bool :$check = True,

    #| Redirects stderr to stdout. Default is False.
    Bool :$merge,

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

    my \iterable = do {
        my $d = $str ?? False !! $chomp;
        if $merge {
            $bin-out ?? $proc.Supply(:bin).list
                     !! $proc.Supply(:$enc, :$translate-nl).lines(:chomp($d)).list;
        } else {
            $bin-out ?? $proc.stdout(:bin).list
                     !! $proc.stdout.lines(:chomp($d)).list
        }
    } if $iter || $str;

    my $proc-run = $proc.start(:ENV($env), :$cwd);

    # Set up a chain of promises that write to the stdin of the proc in
    # input order and closes the stdin at the end.
    my @input-writes;
    with $input {
        my $method = $bin-in ?? "write" !! "print";
        my $cur = start {};
        for $input -> $data {
            $cur = $cur.then: {
                my $promise = $proc."$method"($data);
                @input-writes.push: $promise;
                await $promise;
            }
        }
        $cur.then: { await $proc.close-stdin };
    }

    my @promises := $proc-run, @input-writes, $proc, iterable;

    if $iter || $str {
        if $str {
            my $result = iterable.join('');
            my $*PIPED-PROCS = Channel.new;
            $*PIPED-PROCS.send: @promises;
            my $proc = (try await-procs) // $!.procs[*-1];
            $proc.sink if $check && $proc.exitcode ≠ 0;
            return $chomp ?? $result.chomp !! $result;
        } else {
            $*PIPED-PROCS.send: @promises;
            return iterable;
        }
    } else {
        my $*PIPED-PROCS = Channel.new;
        $*PIPED-PROCS.send: @promises;
        return (try await-procs) // $!.procs[*-1];
    }
}


class BrokenPipeline is Exception {

    has $.error of Exception is rw;
    has @.procs where Proc|Failure;
    has @.writes; # of array of Int or Failure

    method message { "Proc pipeline failed with errors!" }

    method gist {
        my @errors;
        if $!error {
            @errors.push: "\n--- Block exception: --------";
            @errors.push: $!error.gist;
        }
        for @!procs Z, @!writes Z, ^∞ -> ($proc, @writes, $i) {
            my $failure;
            given $proc {
                when Failure {
                    $failure = .exception.gist;
                }
                when .exitcode ≠ 0 {
                    $failure = "Process (pipe $i) exited unsuccessfully!\n";
                    $failure ~= "Command: {$proc.command.perl}\n";
                    $failure ~= "Exit code: {$proc.exitcode}\n";
                }
            }

            my @write-errors;
            @write-errors.append: @!writes[$i].grep(Failure)».exception».gist;

            if $failure || @write-errors {
                @errors.push: "\n--- Proc failure: -----------";
                @errors.push: $failure if $failure;
                if @write-errors {
                    @errors.push: "\n------ Write errors:";
                    @errors.push: @write-errors.join("\n");
                }
            }
        }
        return @errors.join("\n");
    }
}


multi sub run(&block, :$check = True) is export(:DEFAULT, :run) {
    my $*PIPED-PROCS = Channel.new;
    try my $result := block();
    try await-procs $!, :SIGPIPE;
    if $check {
        $!.rethrow if $!;
        return $result;
    } else {
        return $result, $!;
    }
}


sub await-procs($error?, :$SIGPIPE=False) {
    my @writes;
    my @procs;

    $*PIPED-PROCS.close;
    for $*PIPED-PROCS.list -> (
        Promise:D $proc-run, @input-writes,
        Proc::Async:D $proc, \iterable
    ) {

        # Try to close stdin again in case the write promise chain has
        # been broken.
        $proc.close-stdin if $proc.w;

        # Signal the child process that we are done with the pipe;
        # Do it in 1s to give the process a chance to exit.
        $proc.ready.then: {
            Promise.in(1).then: { $proc.kill(Signal::SIGPIPE) }
        } if $SIGPIPE;

        my @results := ((try await $_) // Failure.new($!) for @input-writes);
        @writes.push: @results if @results;

        sink iterable.Seq if iterable.defined;  # needed to ensure $proc-run will be kept.
        @procs.push: (try await $proc-run) // Failure.new($!);
    }

    if $error || @writes.any.any ~~ Failure || @procs.grep({$_ ~~ Failure or .exitcode}) {
        given (my $e = BrokenPipeline.new) {
            .error = $error if $error;
            .procs = @procs;
            .writes = @writes;
            .throw;
        }
    }
    return @procs[*-1];
}




sub proc(
    \command where Str:D|List:D,
    $input? is raw,

    Bool :$check = True,
    Bool :$bin,    # only applies to input.

    :$cwd = $*CWD,
    Hash() :$env = %*ENV,
    :$shell where Bool:D|Str:D = False,
    :$scheduler = $*SCHEDULER

) is export(:DEFAULT, :proc) {
    _proc_impl(command, $input, :!str, :!iter,
               :$check,
               :bin($bin ?? 'IN' !! False),
               :$cwd, :$env,
               :$shell, :$scheduler
    );
}

sub capture(
    \command where Str:D|List:D,
    $input? is raw,

    Bool :$check = True,
    Bool :$chomp = True,
    Bool :$merge,
    Bool :$bin,    # only applies to input.

    Str:D :$enc = 'UTF-8',
    Bool :$translate-nl = True,
    :$cwd = $*CWD,
    Hash() :$env = %*ENV,
    :$shell where Bool:D|Str:D = False,
    :$scheduler = $*SCHEDULER

    --> Str:D

) is export(:DEFAULT, :capture) {
    _proc_impl(command, $input, :str, :!iter,
               :$check, :$chomp, :$merge,
               :bin($bin ?? 'IN' !! False),
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

    Bool :$merge,

    Str:D :$enc = 'UTF-8',
    Bool :$translate-nl = True,
    :$cwd = $*CWD,
    Hash() :$env = %*ENV,
    :$shell where Bool:D|Str:D = False,
    :$scheduler = $*SCHEDULER

) is export(:DEFAULT, :pipe) {

    $chomp //= do given $bin {
        when 'IN'  { True  }
        when 'OUT' { False }
        default    { !$bin }
    }
    _proc_impl(command, $input, :iter, :!str,
               :$chomp, :$merge, :$bin,
               :$enc, :$translate-nl,
               :$cwd, :$env,
               :$shell,
               :$scheduler
    );
}


sub each(&code, $input? is raw) is export(:each) { code($_) for $input }

sub gather-with(&code, $input? is raw) is export(:gather-with) {
    gather code($input);
}

sub quote(Str $s --> Str) is export(:quote) { "'{$s.subst("'", Q/'\''/)}'" }
