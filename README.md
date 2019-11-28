# Introduction
`Proc::Feed` provides a couple wrappers for `Proc::Async` that are 
more convenient to use than the `run` and `shell` subs. Specifically, these
wrappers let you easily feed data to them and also from them to other
callables using the feed operator (`==>` or `<==`).

---
## `sub proc`

```perl6
sub proc(
    \command where Str:D|List:D,
    $input? is raw,

    Bool :$check = False,

    :$bin where 'IN' | {! .so} = False,  # i.e., only :bin<IN> or :!bin

    :$stderr where Any|Callable:D|Str:D|IO::Handle:D,

    :$shell where Bool:D|Str:D = False,

    :$cwd = $*CWD,
    Hash() :$env = %*ENV,

    :$scheduler = $*SCHEDULER

    --> Proc:D

) is export(:DEFAULT, :proc);
```

Use the `proc` sub to run a command when you don't need to capture its
output(`STDOUT`):

```perl6
    proc <<ls -la "READ ME.txt">>;
```

Here we passed a list, of which the first element is the executable, while the
rest are arguments passed to the executable.

> **NOTE**: `proc` blocks until the external command is completed and returns
> a `Proc` object, which when sunk throws an exception if the command exited
> with a non-zero status.

It's also possible to redirect `STDERR` if desired:

```perl6
    # Redirect STDERR to /dev/null
    proc <ls whatever>, :stderr('/dev/null/');

    # Same thing; but with a file we opened
    my $black-hole = open('/dev/null', :w);
    proc <ls whatever>, :stderr($black-hole);
    $black-hole.close;

    # Same effect that ignores error messages; this time, with a callable
    # that just ignores the lines from STDERR.
    proc <ls whatever>, :stderr({;});
```

Sometimes it can be convenient to run a command via a shell (defaults to
`/bin/bash`) if you need to use the features (e.g., globbing, I/O redirection,
... etc) it provides:

```perl6
    proc(['ls -la ~/.*'], :shell);
```

One can also simply pass a single string (recommended when using `:shell`)
instead of a list if not passing any arguments to the command from Perl 6:

```perl6
    proc('ls -la ~/.*', :shell);
```

However, if a list is passed, any remaining elements of the list are passed to
the shell as positional arguments, which will be available as `$1`, `$2`, ...,
and so on, in the shell command/script:

```perl6
    proc(['md5sum "$1" | cut -d" " -f1 > "$1.md5"', "$*PROGRAM"], :shell);

    # ~/.* is not expanded here because it will be passed as an argument to bash.
    proc(<<ls -la ~/.*>>, :shell);  # runs:  bash -c 'ls' - bash '-la' '~/.*'

    # prints an empty line
    proc(<<echo hello world>>, :shell)

    # prints hello world
    proc(<<'echo "$@"' hello world>>, :shell)

    # prints the passed args; also shows you can specify the shell to use.
    proc([q:to/EOF/, 'arg1', 'arg2'], :shell</usr/local/bin/bash>);
    echo "Using SHELL - $0"
    echo "First argument is: $1"
    echo "Second argument is: $2"
    EOF
```
---
## `sub capture`

```perl6
sub capture(
    \command where Str:D|List:D,
    $input? is raw,

    Bool :$check = True,
    Bool :$chomp = True,
    Bool :$merge,

    :$bin where 'IN' | {! .so} = False,  # i.e., only :bin<IN> or :!bin

    :$stderr where Any|Callable:D|Str:D|IO::Handle:D,

    :$shell where Bool:D|Str:D = False,

    Str:D :$enc = 'UTF-8',
    Bool :$translate-nl = True,

    :$cwd = $*CWD,
    Hash() :$env = %*ENV,

    :$scheduler = $*SCHEDULER

    --> Str:D

) is export(:DEFAULT, :capture);
```

To capture the `STDOUT` of a command use the `capture` sub, which returns a `Str:D`
instead of a `Proc`:

```perl6
    capture(<<md5sum "$*PROGRAM">>).split(' ')[0] ==> spurt("$*PROGRAM.md5");

    # You can still run command via a shell
    my $ls = capture('ls -la ~/.*', :shell);

    my $err = capture(<<ls -la "doesn't exist">>, :merge);
    #
    # :merge redirects STDERR to STDOUT, so error messages are also
    # captured in this case.
```

> **NOTE**: By default, similar to *command substitution* in Bash, any trailing
> newline of the captured output is removed. You can disable this behavior by
> specifying `:!chomp`.

> **NOTE**: If the command run by `capture` fails with a non-zero exit
> status, an exception will be thrown.  You can disable this behavior with
> `:!check`, and in which case, an empty string will be returned if the command
> fails.

You can easily feed iterable inputs to a `capture`: (you can do the same with
`proc` or `pipe` too):

```perl6
    my $data = slurp("$*HOME/.bashrc");
    my $chksum = ($data ==> capture('md5sum')).split(' ')[0];
```

By default, both input and output are assumed to be lines of strings, but you
can specify both to be binary with `:bin`, or only one of which to be binary
with either `:bin<IN>` or `:bin<OUT>`:

> **NOTE**: For `capture` and `proc`, only `:bin<IN>` (default) and `:!bin`
> are possible.

```perl6
    # Binary (Blob) in; string (Str) out.
    my $blob = Blob.new(slurp("/bin/bash", :bin));
    my $chksum = ($blob ==> capture('md5sum', :bin<IN>)).split(' ')[0];

    # String (Str) in; binary (Blob) out.
    # See below for more details on using 'run' and 'pipe'.
    run {
        my $f = "$*HOME/.bashrc";
        my $gzipped = open("$f.gz", :w:bin);
        LEAVE $gzipped.close;
        slurp($f) \
        ==> pipe(<gzip -c>, :bin<OUT>)
        ==> each { spurt $gizpped, :bin }
    }
```

> **NOTE**: It makes no sense to feed from a `proc` (i.e., `proc(…) ==> …`) because
> `proc(…)` returns a `Proc`, which is not iterable.
---

## `sub pipe`

```perl6
sub pipe(
    \command where Str:D|List:D,
    $input? is raw,

    Bool :$chomp is copy,

    :$bin where {
        $_ ~~ Bool:D|'IN'|'OUT' and (
            # if :bin or :bin<OUT> then :chomp shouldn't be specified.
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

) is export(:DEFAULT, :pipe);
```

Finally, `pipe` returns an iterable of the output from the `STDOUT` of the
external process, so you can feed it to another callable. By default, text
output is assumed and the output is an iterable of lines. If binary output
is specified, then the output will be an iterable of `Blob`'s.

`pipe` should be used within a `Block` passed to the `run` sub, and it should
not be used at the end of a pipeline where nothing consumes its output. The
`run { ... } ` returns the result returned by the run block. Examples:

```perl6
    # Example
    my $chksum = run {
        slurp("/bin/bash", :bin) \
        ==> pipe('gzip', :bin)
        ==> pipe('md5sum', :bin<IN>)
        ==> split(' ')
        ==> *.[0]()
    }

    # Example
    run {
        my $tarball = open("./somedir.tgz", :w);
        LEAVE $tarball.close;
        pipe «ssh my.remote-host.com "tar -czf - ./somedir"», :bin  \
        ==> each { spurt $tarball, $_ }
    }

    # Example
    my $total = run {
        [+] (pipe «find /var/log -type f» ==> map(*.IO.s))
    } 
```

You must extract the data you want in the `run` block because `run` terminates
all external processes started by `pipe`'s at the end of the block by sending
them the `SIGCHLD` signal.

> **NOTE**: Subs like `map` and `grep` are lazy by default, so they are not
> suitable to be used at the end of a pipeline, unless you also consume the
> entire pipeline with somethig like the `[+]` operator in the above example.
> To consume a pipeline, you can also assign or feed the pipeline to an array,
> or listify the pipeline by using a `==> @` at the end of the pipeline, or
> feed it to a `proc(...)` that consumes STDIN.

By default, `run` throws a `BrokenPipeline` exception if any of the `pipe`
calls fails or exits with non-zero status, or if an exception is propagated
from the block.  You can prevent an exception from being thrown with the
`:!check` option of `run`, in which case it returns a two-element list instead:

```perl6
    my ($result, $err) = run :!check, {
        pipe(<<cat "$*HOME/.bashrc">>) \
        ==> pipe(<gunzip -c>)  # <-- fails because input is not gzipped
        ==> join('')
    }
    if $err {
        put 'Failed decompressing file...';
        say $err;   # $err.gist will show you the errors and stack traces.
    } else {
        put $result;
    }
```

The first item is the return value of the block you passed to `run`; the second
item is a `BrokenPipeline` exception object if there's any.

> **NOTE**: Many code snippets in this doc are made to demo how the various
> functions from this module can be used. They are usually not the most
> efficient way to do the same thing if data have to flow from an external
> process to Perl 6, without any processing, just to flow back to another
> external process. For example, with `run { pipe(<<ls -la>>) ==> proc('nl') }`
> this module currently is not smart enough to connect the `STDOUT` of the first
> process to the `STDIN` of the second process, and therefore the data have to 
> go through Perl 6.


## Other helpers
```perl6
sub each(&code, $input? is raw) is export(:each);
multi sub map(Range \range, &code, $input? is raw) is export(:map);
```
`each`, often used for side effects, makes feeding into a block that
just wants to be called for each item of the iterable fed to it easier:

```perl6
# using each:
(1,2,3,4) ==> each { .say }

# without each:
(1,2,3,4) ==> { .say for $_ }()
```

The `map` multi sub exported by this module takes a `Range` parameter so that
you can limit the code to only a certain range of input a block:

```perl6
# using ranged map:
1,1, * + * ... Inf ==> map ^10, { $_ ** 2 }

# without ranged map:
1,1, * + * ... Inf ==> { gather for $_[^10] { take $_ ** 2 } }()
```

```perl6
sub quote(Str $s --> Str) is export(:quote);
```

`quote` will single-quote a string so that it can be used in a shell script/command
literally:

```perl6
my $file = q/someone's file is > than 1GB/;
put capture("echo {quote $file}", :shell);
```
