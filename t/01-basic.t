use v6;

use Test;
use IO::String;

use lib 'lib';
use Proc::Feed :DEFAULT, :each, :gather-with;

plan :skip-all if $*DISTRO.is-win;

ok proc('echo'), 'Runs a single command without I/O rediretions';
dies-ok { proc "this-command-doesn't-exist" }, 'Command not found raises an exception';
isa-ok proc(<<ls -la>>), Proc, 'Running a non-captured command returns a Proc instance';
dies-ok { sink proc('exit 1', :shell) }, 'Sinking a failed Proc instance raises an exception';
ok proc('exit 99', :shell).exitcode == 99, 'Getting the exit status of a non-captured proc';

is capture(<<echo hello world>>), "hello world",            'Captures STDOUT without the trailing NL - 1';
is capture(<<echo -e 'hello\nworld'>>), "hello\nworld",     'Captures STDOUT without the trailing NL - 2';
is capture(<<echo hello world>>, :!chomp), "hello world\n", 'Captures STDOUT with the trailing NL - 1';
is capture('echo line1; echo line2', :shell, :!chomp), "line1\nline2\n", 'Captures STDOUT with the trailing NL - 2';

is capture('echo ${BASH##*/}', :shell), "bash", 'Default shell is bash';
is capture('echo $0', :shell</bin/sh>), "/bin/sh", "It's possible to specify an different shell"; 

is capture([q:to/EOF/, 1, 2, 3], :shell), "1\n2\n3", 'Running an inline shell script with arguments works - 1';
for i in "$@"; do
    echo $i
done
EOF
my @args := ("arg  1", "arg  2");
is capture(('echo "$@"', |@args), :shell), 'arg  1 arg  2', 'Running an inline shell script with arguments works - 2 ';

is capture('echo error! >&2', :shell, :merge), "error!", 'Redirecting STDERR to STDOUT works - 1';
like capture(<<ls -la adsfasdfs>>, :!check, :merge), /"No such file or directory"/, 'Redirecting STDERR to STDOUT works - 2';

dies-ok { capture('exit 1', :shell) }, 'Capture throws an exception on non-zero exit status by default';
is capture('echo failed >&2; exit 1', :shell, :merge, :!check), 'failed', 'Capture with :!check ignores the exit status';

is ((1..10).join("\n") ~ "\n" ==> capture('cat')), (1..10).join("\n"), 'Feeding a string to capture works - 1';
my $chksum = (qx/echo -n hello | sha1sum/).split(' ')[0];
is ('hello' ==> capture('sha1sum') ==> { .split(' ')[0] }()), $chksum, 'Feeding a string to catpure works - 2';


my @result := run {
    ("$_\n" for ^5).join \
    ==> pipe(q:to/EOF/, :shell)
        set -e
        while read -r line; do
            echo $line
        done
        for ((i=5; i < 10; i++)); do
            echo $i
        done
        EOF
    ==> gather-with {.take for $_[1..7]} \
    ==> map {$_ * 2} \
    ==> @
    # the last @ initiate the "pull" of data on the pipeline,
    # and reify the Seq into a list.
};
is-deeply @result, (2, 4, 6, 8, 10, 12, 14), 'run with a pipeline block works';

my $f = open('/tmp/bash.gz', :bin, :w:a);
run {
    LEAVE { $f.close }
    pipe(<<cat /bin/bash>>, :bin) \
    ==> pipe(<<gzip -c>>, :bin)
    ==> each { $f.spurt($_) }
}
my @tmp-bash;
run {
    [Blob.new(slurp('/tmp/bash.gz', :bin))] \
    ==> pipe(<<gunzip -c>>, :bin)
    ==> @tmp-bash
}
my Buf[uint8] $tmp-bash = Buf[uint8].new(@tmp-bash.map: |*);
my $bash = slurp('/bin/bash', :bin);
ok $tmp-bash eqv $bash, 'run pipeline block works with binary data';
proc <<rm -f /tmp/bash.gz>>;

dies-ok {
  (run {
    pipe(<cat /bin/bash>, :bin) \
    ==> proc('gunzip -c > /dev/null', :bin, :shell)
  })[0]
}, 'Sinking a run with a pipeline block that returns a failed Proc throws an exception';

my $s = run {
    pipe('echo hello world | gzip -c', :bin, :shell) \
    ==> pipe('gunzip -c', :bin<IN>, :shell)
    ==> join('')
};
is $s[0], "hello world";

is (run {
    "hello world" \
    ==> pipe(<gzip -nc> , :bin<OUT>)
    ==> pipe('md5sum', :bin<IN>) ==> split(' ') ==> *.[0]()
}), 'ee6920fa73341cddbab1990b37c29548';

# This should not block.
run {
    pipe('LC_CTYPE=C exec tr -cd a-f0-9 </dev/urandom', :bin, :shell) \
    ==> gather-with { .take for $_[^5] } \
    ==> each { put "DATA:    ", .decode }
}

my ($result, $err) = run :!check, {
    pipe('echo hello world', :shell) \
    ==> pipe(<gunzip -c>)
    ==> join('');
    my @a;
    @a.xxx;
};
ok($err.error ~~ Exception);
ok($err.procs[1].exitcode != 0);

{
    my ($output, $err) = run :!check, {
        pipe(<<gzip -c "$*HOME/.bashrc">>, :bin<OUT>) \
        ==> { die "error" }()
        ==> join('')
    }
    ok($err ~~ Proc::Feed::BrokenPipeline);
}


done-testing;
