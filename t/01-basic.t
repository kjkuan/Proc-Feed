use v6;

use Test;

use lib 'lib';
use Proc::Feed (:DEFAULT, :each, :map);

plan :skip-all if $*DISTRO.is-win;
my $sh = :shell</bin/sh>;

ok proc('echo'), 'Runs a single command without I/O rediretions';
dies-ok { proc "this-command-doesn't-exist" }, 'Command not found raises an exception';
isa-ok proc(<<ls -la>>), Proc, 'Running a non-captured command returns a Proc instance';

dies-ok { sink proc('exit 1', |$sh) }, 'Sinking a failed Proc instance raises an exception';
ok proc('exit 99', |$sh).exitcode == 99, 'Getting the exit status of a non-captured proc';

is capture(<<echo hello world>>), "hello world",            'Captures STDOUT without the trailing NL - 1';
is capture(<<echo -e 'hello\nworld'>>), "hello\nworld",     'Captures STDOUT without the trailing NL - 2';
is capture(<<echo hello world>>, :!chomp), "hello world\n", 'Captures STDOUT with the trailing NL - 1';

is capture('echo line1; echo line2', |$sh, :!chomp), "line1\nline2\n", 'Captures STDOUT with the trailing NL - 2';
if '/bin/bash'.IO.e {
    is capture('echo ${BASH##*/}', :shell), "bash", 'Default shell is bash';
}
is capture('echo $0', |$sh), "/bin/sh", "It's possible to specify an different shell";

is capture([q:to/EOF/, 1, 2, 3], |$sh), "1\n2\n3", 'Running an inline shell script with arguments works - 1';
for i in "$@"; do
    echo $i
done
EOF
my @args := ("arg  1", "arg  2");
is capture(('echo "$@"', |@args), |$sh), 'arg  1 arg  2', 'Running an inline shell script with arguments works - 2 ';

is capture('echo error! >&2', |$sh, :merge), "error!", 'Redirecting STDERR to STDOUT works - 1';
like capture(<<ls -la adsfasdfs>>, :!check, :merge), /"'adsfasdfs'"/, 'Redirecting STDERR to STDOUT works - 2';

dies-ok { capture('exit 1', |$sh) }, 'Capture throws an exception on non-zero exit status by default';
is capture('echo failed >&2; exit 1', |$sh, :merge, :!check), 'failed', 'Capture with :!check ignores the exit status';

is ((1..10).join("\n") ~ "\n" ==> capture('cat')), (1..10).join("\n"), 'Feeding a string to capture works - 1';
my $chksum = (qx/echo -n hello | sha1sum/).split(' ')[0];
is ('hello' ==> capture('sha1sum') ==> { .split(' ')[0] }()), $chksum, 'Feeding a string to catpure works - 2';


my @result := run {
    ("$_\n" for ^5).join \
    ==> pipe(q:to/EOF/, |$sh)
        set -e
        while read -r line; do
            echo $line
        done
        for i in 5 6 7 8 9; do
            echo $i
        done
        EOF
    ==> map 1..7, { $_ } \
    ==> map {$_ * 2} \
    ==> @
    # the last @ initiate the "pull" of data on the pipeline,
    # and reify the Seq into a list.
};
is-deeply @result, (2, 4, 6, 8, 10, 12, 14), 'run with a pipeline block works';

my $f = open('/tmp/sh.gz', :bin, :w:a);
run {
    LEAVE { $f.close }
    pipe(<<cat /bin/sh>>, :bin) \
    ==> pipe(<<gzip -c>>, :bin)
    ==> each { $f.spurt($_) }
}
my @tmp-sh;
run {
    [Blob.new(slurp('/tmp/sh.gz', :bin))] \
    ==> pipe(<<gunzip -c>>, :bin)
    ==> @tmp-sh
}
my Buf[uint8] $tmp-sh = Buf[uint8].new(@tmp-sh.map: |*);
my $sh-bin = slurp('/bin/sh', :bin);
ok $tmp-sh eqv $sh-bin, 'run pipeline block works with binary data';
proc <<rm -f /tmp/sh.gz>>;

dies-ok {
  (run {
    pipe(<cat /bin/sh>, :bin) \
    ==> proc('gunzip -c > /dev/null', :bin, |$sh)
  })[0]
}, 'Sinking a run with a pipeline block that returns a failed Proc throws an exception';

my $s = run {
    pipe('echo hello world | gzip -c', :bin, |$sh) \
    ==> pipe(<gunzip -c>, :bin<IN>)
    ==> join('')
};
is $s[0], "hello world";

is (run {
    "hello world" \
    ==> pipe(<gzip -c> , :bin<OUT>)
    ==> pipe('md5sum', :bin<IN>) ==> split(' ') ==> *.[0]()
}), capture('echo -n hello world | gzip -c | md5sum | cut -d" " -f1', |$sh);

# This should not block.
run {
    pipe('LC_CTYPE=C exec tr -cd a-f0-9 </dev/urandom', :bin, |$sh) \
    ==> map ^5, { $_ } \
    ==> each { put "DATA:    ", .decode }
}

my ($result, $err) = run :!check, {
    pipe('echo hello world', |$sh) \
    ==> pipe(<gunzip -c>)
    ==> join('');
    my @a;
    @a.xxx;
};
ok($err.error ~~ Exception:D);
ok($err.procs[1].exitcode != 0);

{
    my ($output, $err) = run :!check, {
        pipe(<gzip -c /etc/hostname>, :bin<OUT>) \
        ==> { die "error" }()
        ==> join('')
    }
    ok($err ~~ Proc::Feed::BrokenPipeline);
}

{
    my @errors;
    proc <ls whateverdoesnotexist>, :stderr(-> $_ { @errors.push: $_ });
    ok @errors.join ~~ /whateverdoesnotexist/;

    proc <ls whateverdoesnotexist>, :stderr("/tmp/proc-feed-test.err");
    ok '/tmp/proc-feed-test.err'.IO.slurp ~~ /whateverdoesnotexist/;

    my $f = open('/tmp/proc-feed-test.err', :w);
    proc <ls whateverdoesnotexist>, :stderr($f);
    $f.close;
    ok '/tmp/proc-feed-test.err'.IO.slurp ~~ /whateverdoesnotexist/;

    try '/tmp/proc-feed-test.err'.IO.unlink;

    my $capture-error;
    my $out = capture <ls whateverdoesnotexist>,
                      :!check, :stderr(-> $_ { $capture-error = $_ });
    ok $capture-error ~~ /whateverdoesnotexist/;
}


done-testing;
