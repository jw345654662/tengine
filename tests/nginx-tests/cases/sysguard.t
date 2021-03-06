#!/usr/bin/perl

###############################################################################

use warnings;
use strict;

use Test::More;
use File::Copy;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use lib 'lib';
use Test::Nginx;
use Time::Parse;


###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;
my $can_use_threads = eval 'use threads; 1';

plan(skip_all => 'perl does not support threads') if (!$can_use_threads || threads->VERSION < 1.86);
plan(skip_all => 'unsupported os') if (!(-e "/usr/bin/uptime" || -e "/usr/bin/free"));

my $t = Test::Nginx->new()->has(qw/http sysguard/)->plan(8);

$t->set_dso("ngx_http_fastcgi_module", "ngx_http_fastcgi_module.so");
$t->set_dso("ngx_http_uwsgi_module", "ngx_http_uwsgi_module.so");
$t->set_dso("ngx_http_scgi_module", "ngx_http_scgi_module.so");

my $content = <<'EOF';

%%TEST_GLOBALS%%

master_process off;
daemon         off;

%%TEST_GLOBALS_DSO%%

events {
}

http {
    %%TEST_GLOBALS_HTTP%%
    access_log    off;

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        sysguard on;

        location /load_limit {
            root %%TESTDIR%%;
            sysguard_load load=%%load1%% action=/limit;
        }

        location /load_unlimit {
            root %%TESTDIR%%;
            sysguard_load load=%%load2%% action=/limit;
        }

        location /free_unlimit {
            root %%TESTDIR%%;
            sysguard_mem free=%%free1%%k action=/limit;
        }

        location /free_limit {
            root %%TESTDIR%%;
            sysguard_mem free=%%free2%%k action=/limit;
        }

        location /mem_load_limit {
            root %%TESTDIR%%;
            sysguard_load load=%%load1%% action=/limit;
            sysguard_mem free=%%free2%%k action=/limit;
        }

        location /mem_load_limit1 {
            root %%TESTDIR%%;
            sysguard_load load=%%load2%% action=/limit;
            sysguard_mem free=%%free2%%k action=/limit;
        }

        location /mem_load_limit2 {
            root %%TESTDIR%%;
            sysguard_load load=%%load1%% action=/limit;
            sysguard_mem free=%%free1%%k action=/limit;
        }

        location /mem_load_limit3  {
            root %%TESTDIR%%;
            sysguard_load load=%%load2%% action=/limit;
            sysguard_mem free=%%free1%%k action=/limit;
        }

        location /limit {
            return 503;
        }
    }
}

EOF


runload();
my $load = getload($t);

my $load_less = $load - 4.0;
if ($load_less lt 2) {
    $load_less = 0;
}

my $load_up= $load + 4.0;

my $free = getfree($t);
my $free_less = $free - 100000;
my $free_up = $free + 100000;

$content =~ s/%%load1%%/$load_less/gmse;
$content =~ s/%%load2%%/$load_up/gmse;
$content =~ s/%%free1%%/$free_less/gmse;
$content =~ s/%%free2%%/$free_up/gmse;

$t->write_file_expand('nginx.conf', $content);

$t->run();

###############################################################################

like(http_get("/load_limit"), qr/503/, 'load_limit');
like(http_get("/load_unlimit"), qr/404/, 'load_unlimit');

like(http_get("/free_unlimit"), qr/404/, 'free_unlimit');
like(http_get("/free_limit"), qr/503/, 'free_limit');

like(http_get("/mem_load_limit"), qr/503/, 'mem_load_limit');
like(http_get("/mem_load_limit1"), qr/503/, 'mem_load_limit1');
like(http_get("/mem_load_limit2"), qr/503/, 'mem_load_limit2');
like(http_get("/mem_load_limit3"), qr/404/, 'mem_load_limit3');

sub getload
{
    my($t) = @_;
    system("/usr/bin/uptime | awk  '{print \$11}' | awk -F ',' '{print \$1}' > $t->{_testdir}/uptime");
    open(FD, "$t->{_testdir}/uptime")||die("Can not open the file!$!n");
    my @uptime=<FD>;
    close(FD);

    return $uptime[0];
}

sub getfree
{
    my($t) = @_;
    system("/usr/bin/free | grep Mem | awk '{print \$4 + \$6 + \$7}' > $t->{_testdir}/free");
    open(FD, "$t->{_testdir}/free")||die("Can not open the file!$!n");
    my @free=<FD>;
    close(FD);

    return $free[0];
}

sub while_thread
{
    $SIG{'KILL'} = sub { threads->exit(); };
    my $j = 0;
    my $i = 0;
    for ($i = 0; $i<=1000000000; $i++) {
        $j = $j + 1;
    }
}

sub runload
{
    my $i = 0;
    my @ths;
    for ($i = 0; $i<=8; $i++) {
        $ths[$i] = threads->create( \&while_thread);
    }

    sleep(10);
    for ($i = 0; $i<=8; $i++) {
        $ths[$i]->kill('KILL')->detach();
    }
}
