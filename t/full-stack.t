#! /usr/bin/perl

# Copyright (C) 2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Cwd qw(abs_path getcwd);

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_CONFIG}  = 't/full-stack.d/config';
    $ENV{OPENQA_BASEDIR} = abs_path('t/full-stack.d');
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Data::Dumper;
use IO::Socket::INET;
use Cwd qw(abs_path getcwd);
use POSIX '_exit';

# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional 'can_load';

plan skip_all => "set FULLSTACK=1 (be careful)" unless $ENV{FULLSTACK};

my $workerpid;
my $wspid;
my $schedulerpid;

sub turn_down_stack {
    if ($workerpid) {
        kill TERM => $workerpid;
        waitpid($workerpid, 0);
    }

    if ($wspid) {
        kill TERM => $wspid;
        waitpid($wspid, 0);
    }

    if ($schedulerpid) {
        kill TERM => $schedulerpid;
        waitpid($schedulerpid, 0);
    }

}

unlink('t/full-stack.d/db/db.sqlite');
open(my $conf, '>', 't/full-stack.d/config/database.ini');
print $conf <<EOC;
[production]
dsn = dbi:SQLite:dbname=t/full-stack.d/db/db.sqlite
on_connect_call = use_foreign_keys
on_connect_do = PRAGMA synchronous = OFF
sqlite_unicode = 1
EOC
close($conf);
system("perl ./script/initdb --init_database");
# make sure the assets are prefetched
Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0');

use t::ui::PhantomTest;

# skip if phantomjs or Selenium::Remote::WDKeys isn't available
use IPC::Cmd 'can_run';
if (!can_run('phantomjs') || !can_load(modules => {'Selenium::Remote::Driver' => undef,})) {
    return undef;
}

$schedulerpid = fork();
if ($schedulerpid == 0) {
    use OpenQA::Scheduler;
    OpenQA::Scheduler::run;
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);
}

# we don't want no fixtures
my $mojoport = t::ui::PhantomTest::start_app(sub { });
my $driver = t::ui::PhantomTest::start_phantomjs($mojoport);

remove_tree('t/full-stack.d/openqa/testresults/');
make_path('t/full-stack.d/openqa/testresults/');
remove_tree('t/full-stack.d/openqa/images/');

is($driver->get_title(), "openQA", "on main page");
is($driver->find_element('#user-action', 'css')->get_text(), 'Login', "noone logged in");
$driver->find_element('Login', 'link_text')->click();
# we're back on the main page
is($driver->get_title(), "openQA", "back on main page");
# but ...

my $wsport = $mojoport + 1;
$wspid = fork();
if ($wspid == 0) {
    $ENV{MOJO_LISTEN} = "http://127.0.0.1:$wsport";
    use OpenQA::WebSockets;
    OpenQA::WebSockets::run;
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);
}
else {
    # wait for websocket server
    my $wait = time + 20;
    while (time < $wait) {
        my $t      = time;
        my $socket = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $wsport,
            Proto    => 'tcp'
        );
        last if $socket;
        sleep 1 if time - $t < 1;
    }
}

my $connect_args = "--apikey=1234567890ABCDEF --apisecret=1234567890ABCDEF --host=http://localhost:$mojoport";

unlink("t/full-stack.d/openqa/factory/iso/pitux-0.3.2.iso");
symlink(abs_path("../os-autoinst/t/data/pitux-0.3.2.iso"), "t/full-stack.d/openqa/factory/iso/pitux-0.3.2.iso")
  || die "can't symlink";

make_path('t/full-stack.d/openqa/share/tests');
unlink('t/full-stack.d/openqa/share/tests/pitux');
symlink(abs_path('../os-autoinst/t/data/tests/'), 't/full-stack.d/openqa/share/tests/pitux')
  || die "can't symlink";

sub client_call {
    my ($args) = @_;
    my $ret = system("perl ./script/client $connect_args $args");
    is($ret, 0, "Client $args succeeded");
}

# schedule job
client_call(
"jobs post ISO=pitux-0.3.2.iso DISTRI=pitux ARCH=i386 QEMU=i386 QEMU_NO_KVM=1 FLAVOR=flavor BUILD=1 MACHINE=coolone "
      . "QEMU_NO_TABLET=1 QEMU_NO_FDC_SET=1 CDMODEL=ide-cd HDDMODEL=ide-drive VERSION=1 TEST=pitux");


# verify it's displayed scheduled
$driver->find_element('All Tests', 'link_text')->click();
is($driver->get_title(), 'openQA: Test results', 'tests followed');
like($driver->get_page_source(), qr/\Q<h2>1 scheduled jobs<\/h2>\E/, '1 job scheduled');
t::ui::PhantomTest::wait_for_ajax;

$driver->find_element('pitux@coolone', 'link_text')->click();
is($driver->get_title(), 'openQA: pitux-1-flavor-i386-Build1-pitux@coolone test results', 'scheduled test page');
like($driver->find_element('#result-row .panel-body', 'css')->get_text(), qr/State: scheduled/, 'test 1 is scheduled');

$workerpid = fork();
if ($workerpid == 0) {
    exec("perl ./script/worker --instance=1 $connect_args --isotovideo=../os-autoinst/isotovideo --verbose");
    die "FAILED TO START WORKER";
}

my $count;
for ($count = 0; $count < 30; $count++) {
    last if $driver->find_element('#result-row .panel-body', 'css')->get_text() =~ qr/State: running/;
    sleep 1;
}

$driver->refresh();
print "RUNING after $count seconds\n";
like($driver->find_element('#result-row .panel-body', 'css')->get_text(), qr/State: running/, 'test 1 is running');

for ($count = 0; $count < 30; $count++) {
    print $driver->find_element('#result-row .panel-body', 'css')->get_text();
    last if $driver->find_element('#result-row .panel-body', 'css')->get_text() =~ qr/Result: passed/;
    sleep 1;
}

print "PASSED after $count seconds\n";
system(
    'cat t/full-stack.d/openqa/testresults/00000/00000001-pitux-1-flavor-i386-Build1-pitux@coolone/autoinst-log.txt');
$driver->refresh();
like($driver->find_element('#result-row .panel-body', 'css')->get_text(), qr/Result: passed/, 'test 1 is passed');

ok(-s 't/full-stack.d/openqa/testresults/00000/00000001-pitux-1-flavor-i386-Build1-pitux@coolone/autoinst-log.txt',
    'log file generated');

client_call("jobs/1/restart post");


turn_down_stack;
t::ui::PhantomTest::kill_phantom();
done_testing;
exit(0);

# in case it dies
END {
    turn_down_stack;
    $? = 0;
}

