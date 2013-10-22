#!perl
# /* Copyright 2013 Proofpoint, Inc. All rights reserved.
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# */


package PPOPS::Herd;
use strict;
use warnings;
use Carp;
use Data::Dumper;

=head1 NAME

PPOPS::Herd - Manage a herd of daemons

=head1 SYNOPSIS

   package PPOPS::Herd::Mydaemon;
   use PPOPS::Herd;
   use base qw(PPOPS::Herd);

   sub instances {
      my ($self) = @_;

      return qw(one two three);
   }

=head1 DESCRIPTION

The PPOPS::Herd class is a base class which can be inherited to provide
daemon management functionality. It provides methods for starting, stopping,
reloading and ensuring the running of a group of daemons.

Child classes override the Abstract Methods to provide a list of daemon
instances and information about starting and stopping them. In the typical
case the child class really only needs to provide a way of getting a list of
instances, the pidfile each maintains, and the command-line for invoking one.
For more complicated scenarios, the child class can override the status, start
and stop methods as well.

=head2 Methods

=over 4

=item new($config)

Initialize a new herd manager, optionally using the config. Subclasses should
not generally need to provide their own C<new()> method, but use C<init()>
instead.

=cut

sub new {
   my ($class, $config) = @_;

   my $self = bless({ }, $class);

   $self->{'config'} = $config;

   my $default_config = {
      'timely-config' => 1,
      'wait-interval' => 1,
      'wait-timeout' => 60
   };

   for my $key (keys %{$default_config}) {
      $self->{'config'}->{$key} = $default_config->{$key}
         unless exists($self->{'config'}->{$key});
   }

   $self->dbg("Initializing object");
   $self->init();

   return $self;
}

sub herdcmd {
   my ($self) = @_;

   return 'herdcmd';
}

=back

=head2 Logging Methods

=over 4

=item logger($callback)

Set the logging callback. This callback is a code reference expected to accept
two arguments: the string priorities given in L<Sys::Syslog>, and a message.

=cut

sub logger {
   my ($self, $callback) = @_;

   if (ref($callback) and ref($callback) eq 'CODE') {
      $self->{'logger'} = $callback;
   }

   return $self->{'logger'};
}

=item logmsg($priority, $message)

Log a message. If no callback was given, no message is logged.

=cut

sub logmsg {
   my ($self, $pri, $msg) = @_;

   eval {
      if ($self->{'logger'} and ref($self->{'logger'})
             and ref($self->{'logger'}) eq 'CODE') {
         $self->{'logger'}->($pri, $msg);
      }
   };
   if ($@) {
      carp "$0 warning: Invalid logger: $@";
   }
}

=item wrn($msg)

Print a warning via carp and log a 'warning' message.

=cut

sub wrn {
   my ($self, $msg) = @_;
   carp "$0 warning: $msg";
   $self->logmsg('warning', $msg);
}

=item fatal($msg)

Logs a 'crit' message and croaks.

=cut

sub fatal {
   my ($self, $msg) = @_;
   $self->logmsg('crit', $msg);
   croak($msg);
}

=item notice($message)

Logs a 'notice' message.

=cut

sub notice {
   my ($self, $msg) = @_;
   $self->logmsg('notice', $msg);
   $self->_print_dbg($msg);
}

=item dbg($message)

Logs a 'debug' message. Also, if the 'debug' config option is 2 or more,
prints the message in a helpful format to stdout.

=cut

sub dbg {
   my ($self, @msg) = @_;
   map { $self->logmsg('debug', $_) } @msg;
   $self->_print_dbg(@msg);
}

sub _print_dbg {
   my ($self, @msg) = @_;
   print "DBG(" . ref($self) . "): ",
      join("\nDBG(" . ref($self) . "):   ", @msg), "\n"
         if defined($self->{'config'}->{'debug'})
            and $self->{'config'}->{'debug'} > 1;
}

=item show_status($status)

Format the instances statuses from the status hash.

=cut

sub show_status {
   my ($self, $status) = @_;

   return join(' ', map { "$_=$status->{$_}" } keys %$status);
}

=back

=head2 Control Methods

Subclasses of PPOPS::Herd should not generally need to override these methods.
See L<Abstract Methods>, below.

=over 4

=item start()
=item start(@instances)

Start the herd. Uses start_one() on each instance. Returns an instance status
hash. (Every instance should be 'running', but they might not be if, for
example, PPOPS::Herd waited to long to wait for them to start--greater than
C<wait-timeout> seconds.)

=cut

sub start {
   my ($self, @instances) = @_;
   my $status = { };
   @instances = $self->instances() unless @instances;

   $self->notice("starting herd (" . join(', ', @instances) . ")");
   $self->update_config();

   for my $instance (@instances) {
      $self->start_one($instance);
   }
   # Give it a chance to do something
   sleep(2 * $self->{'config'}->{'wait-interval'});

   my $count = $self->waitfor('running', @instances);
   if ($count == scalar(@instances)) {
      $status = { map { ($_, 'running') } @instances };
   } else {
      $status = $self->status(@instances);
   }

   $self->notice("herd status: " . $self->show_status($status));

   return $status;
}

sub count_status {
   my ($self, $status, @instances) = @_;

   return scalar(grep { $_ eq $status } map { $self->status_one($_) }
                    @instances);
}

sub waitfor {
   my ($self, $status, @instances) = @_;

   my $count = $self->count_status($status, @instances);
   my $t0 = time();

   while ($count < scalar(@instances)) {
      last if time() - $t0 > $self->{'config'}->{'wait-timeout'};
      sleep $self->{'config'}->{'wait-interval'};
      $count = $self->count_status($status, @instances);
   }

   return $count;
}

=item start_one($instance)

Start one instance.

=cut

sub start_one {
   my ($self, $instance) = @_;

   my @cmdline = $self->cmdline($instance);
   my $pidfile = $self->pidfile($instance);
   unlink($pidfile) if -f $pidfile;
   $self->run($instance, @cmdline);

}

=item stop()
=item stop(@instances)

Stop the herd. Returns an instance status hash. All services should be running
but they might have failed to start in the time allotted.

=cut

sub stop {
   my ($self, @instances) = @_;
   my $status;

   @instances = $self->instances() unless @instances;

   $self->notice("stopping herd");

   for my $instance (@instances) {
      $self->stop_one($instance);
   }
   # Give it a chance to do something
   sleep(2 * $self->{'config'}->{'wait-interval'});

   my $count = $self->waitfor('stopped', @instances);

   if ($count == scalar(@instances)) {
      $status = { map { ($_, 'stopped') } @instances };
   } else {
      $status = $self->status(@instances);
      my @running = grep { $status->{$_} eq 'running' } keys %$status;
      if (@running) {
         $self->wrn("herd stopped but instances still running: "
                       . join(', ', @running));
      }
   }

   $self->notice("herd status: " . $self->show_status($status));

   return $status;
}

=item stop_one($instance)

Stop one instance.

=cut

sub stop_one {
   my ($self, $instance) = @_;

   my $pidfile = $self->pidfile($instance);
   if (-f $pidfile) {
      my $pid = $self->_getpid($pidfile);
      unless ($self->{'config'}->{'dry-run'}) {
         if (kill(15, $pid)) {
            $self->notice("stopping $instance\[$pid\]");
         } else {
            $self->wrn("stopping non-running instance $instance");
         }
      }
   } else {
      $self->wrn("stopping non-running instance $instance " .
                    "(no pidfile $pidfile)");
   }
}

=item restart()
=item restart(@instances)

Restart the herd (or list of instances): stop it, then start it. Uses stop()
and start_one().  There's no restart_one() because PPOPS::Herd tries not to
wait for things serially like that. Because it uses stop() and start(), it
waits for the whole herd to stop before starting the herd again, it doesn't
restart them individually.

=cut

sub restart {
   my ($self, @instances) = @_;
   my @stopped;

   my $status = $self->stop(@instances);
   for my $instance (@instances) {
      if ($status->{$instance} eq 'stopped') {
         push(@stopped, $instance);
         $self->start_one($instance);
      } else {
         $self->wrn("not restarting instance $instance, did not stop");
      }
   }
   my $count = $self->waitfor('running', @stopped);
   $status = $self->status(@instances);
   if ($count < scalar(@stopped)) {
      for my $instance (@stopped) {
         if ($status->{$instance} eq 'stopped') {
            $self->wrn("instance $instance did not restart");
         }
      }
   }

   $self->notice("herd status: " . $self->show_status($status));

   return $status;
}

=item reload()

Reload the herd's configuration. This method reloads them whether they
"need" it or not (that is, ignores C<timely-config> and config_age()).

=cut

sub reload {
   my ($self, @instances) = @_;


   @instances = $self->instances() unless @instances;

   $self->notice("reloading herd: " . join(', ', @instances));
   $self->update_config();

   my ($huppable, $nonhuppable) = $self->listsplit(
      sub { $self->huppable($_[0]) },
      @instances);

   $self->dbg("huppable: " . join(', ', @$huppable));
   $self->dbg("nonhuppable: " . join(', ', @$nonhuppable));

   for my $instance (@$huppable) {
      $self->reload_one($instance);
   }
   if (@$nonhuppable) {
      $self->restart(@$nonhuppable);
   }

   my $status = $self->status(@instances);

   $self->notice("herd status: " . $self->show_status($status));

   return $status;
}

sub listsplit {
   my ($self, $condition, @list);
   my $true = [ ];
   my $false = [ ];

   for my $el (@list) {
      if ($condition->($el)) {
         push(@$true, $el);
      } else {
         push(@$false, $el);
      }
   }

   return ($true, $false);
}


=item reload_one($instance)

Reload one instance. See also C<huppable()>.

=cut

sub reload_one {
   my ($self, $instance) = @_;

   if ($self->huppable($instance)) {
      my $pidfile = $self->pidfile($instance);
      if (-f $pidfile) {
         my $pid = $self->_getpid($pidfile);
         unless ($self->{'config'}->{'dry-run'}) {
            if (kill(1, $pid)) {
               $self->notice("hupped instance $instance\[$pid\]");
            } else {
               $self->wrn("could not hup instance $instance\[$pid\]");
            }
         }
      } else {
         $self->wrn("can't reload instance " .
                       "$instance, no pidfile $pidfile");
      }
   } else {
      $self->stop_one($instance);
      my $count = $self->waitfor('stopped', $instance);
      if ($count) {
         $self->start_one($instance);
         my $started = $self->waitfor('running', $instance);
         $self->wrn("instance $instance did not start again after reloading")
            unless $started;
      } else {
         $self->wrn("can't reload instance $instance, would not stop");
      }
   }
}

=item status()

Return status hash for the herd. That's hash where the keys are instance names
and the values are status strings.

=cut

sub status {
   my ($self) = @_;
   my $status = { };
   my @instances = $self->instances();

   for my $instance (@instances) {
      $status->{$instance} = $self->status_one($instance);
   }

   return $status;
}

=item status_one($instance)

Return status of instance. Valid statuses are 'running' or 'stopped'.

=cut

sub status_one {
   my ($self, $instance) = @_;
   my $status;

   my $pidfile = $self->pidfile($instance);
   if (-f $pidfile) {
      my $pid = $self->_getpid($pidfile);
      # Technically this isn't really true. If the daemon died, leaving its
      # pidfile, and another process now has the id, it would be "running"
      # here but it's not. There's no way to check this in general.
      # -jdb/20101020
      if (kill(0, $pid)) {
         $status = 'running';
      } else {
         $status = 'stopped';
      }
   } else {
      $status = 'stopped';
   }

   return $status;
}

=item ensure()

Ensures the herd is running correctly.

=over 8

=item *

Updates the configuration. If C<timely-config> is true (the default), reloads
those instances.

=item *

Determines if any instances are running with an old config, and reloads them

=item *

Restarts any stopped instances.

=item *

If any instances should be stopped, stops them.

=back

=over 4

=cut

sub ensure {
   my ($self, @instances) = @_;
   my $to_reload = { };
   my $to_start = { };
   my $status;
   my $changed;
   my $ensure_all = 0;

   unless (@instances) {
      @instances = $self->instances();
      $ensure_all = 1;
   }
   $self->notice("ensuring herd: " . join(', ', @instances));
   $changed = { map { ($_, 1) } $self->update_config() };

   $status = $self->status(@instances);
   for my $instance (@instances) {
      if ($status->{$instance} ne 'running') {
         $self->notice("instance $instance is not running, will start");
         $to_start->{$instance} = 1;
      }
   }
   if ($self->{'config'}->{'timely-config'}) {
      for my $instance (@instances) {
         next if $to_start->{$instance};
         if ($changed->{$instance}) {
            $self->notice("instance $instance config has changed, will reload");
            $to_reload->{$instance} = 1;
            next;
         }
         my $pidfile = $self->pidfile($instance);
         my $t_started = (stat($pidfile))[9];
         my $t_conf = $self->config_age($instance);
         if ($t_conf > $t_started) {
            $self->notice("instance $instance config is old, will reload");
            $to_reload->{$instance} = 1;
         }
      }
   }
   $self->start(keys %$to_start) if keys %$to_start;
   $self->reload(keys %$to_reload) if keys %$to_reload;

   $status = $self->status(@instances);

   my @to_stop = $self->to_stop();
   if ($ensure_all and @to_stop) {
      for my $badinstance ($self->to_stop()) {
         $self->notice("stopping extraneous instance $badinstance");
         $self->stop_one($badinstance);
      }
      my $count = $self->waitfor('stopped', @to_stop);
      if ($count == scalar(@to_stop)) {
         for my $badinstance (@to_stop) {
            $status->{$badinstance} = 'stopped (unconfigured)';
         }
      } else {
         my $badstatus = $self->status(@to_stop);
         for my $badinstance (@to_stop) {
            $status->{$badinstance} =
               "$badstatus->{$badinstance} (unconfigured)";
         }
      }
   }

   $self->notice("herd status: " . $self->show_status($status));

   return $status;
}

=item run($instance, @cmd)

Run the specified command using system() and produce warnings for unsuccessful
executions.

=cut

sub run {
   my ($self, $instance, @cmdline) = @_;
   my $rc = 'success';

   $self->notice("executing '" . join(' ', @cmdline) . "'");
   unless ($self->{'config'}->{'dry-run'}) {
      system(@cmdline);
      $self->dbg("   raw return value: $?");
      if ($? == -1) {
         $self->wrn("starting $instance: couldn't execute "
                       . join(' ', @cmdline) . ": $!");
         $rc = 'fail (exec failed)';
      } elsif ($? & 127) {
         $self->wrn(sprintf("starting $instance: '" .
                               join(' ', @cmdline) .
                                  "' died with signal %d, %s coredump",
                            ($? & 127),  ($? & 128) ? 'with' : 'without'));
         $rc = sprintf('fail (sig%d)', ($? & 127));
      } elsif ($? >> 8 != 0) {
         $self->wrn(sprintf("starting $instance: '" .
                               join(' ', @cmdline) .
                                  "' exited with value %d", $? >> 8));
         $rc = sprintf('fail (%d)', $? >> 8);
      } else {
         $self->dbg("   apparent success");
      }
   }
   return $rc;
}

=back

=head2 Abstract methods

Subclasses should override instances(), pidfile(), config_age() and cmdline()
at a minimum. For typical commands with one process, a pidfile, and a command
line, that should be sufficient.

=over 4

=item init()

Called when the object is created. This is a good place to examine the system
and determine and store the instance list.

=cut

sub init {
}

=item instances()

Returns a list of instance names.

=cut

sub instances {
   my ($self) = @_;

   return ($self->herdcmd());
}

=item pidfile($instance)

Return the pidfile of the instance. If your application does not maintain a
pidfile, you'll need to override L<status_one()> instead.

=cut

sub pidfile {
   my ($self, $instance) = @_;

   return "/var/run/$instance.pid";
}

=item cmdline($instance)

Returns the command line used to run the instance. The command line is a list
of arguments suitable for system().

=cut

sub cmdline {
   my ($self, $instance) = @_;

   return ($instance);
}

=item config_age($instance)

By default (if the C<timely-config> option is set), ensure reloads instances
whose configuration is out of date (because they changed--see update_config;
or because they are newer than the pidfile.

=cut

sub config_age {
   my ($self) = @_;

   return (stat("/etc/" . $self->herdcmd() . ".conf"))[9];
}

=item huppable($instance)

Returns 1 if instance can be reloaded by sending a HUP signal. Otherwise,
uses stop and start.

=cut

sub huppable {
   my ($self, $instance) = @_;

   return 0;
}

=item update_config()

Update the configuration of the name instance. Called when starting, reloading
or ensuring the herd. Returns a list of instances whose configuration has
changed.

=cut

sub update_config() {
}

=item to_stop()

Called by ensure(), which will stop the instances returned by this method. You
might use this when you can find all instances of your application, but some
are not configured to run, and you want to make sure that when they are not
configured to run via the herd, you shut them down.

Note also that these should not be instances returned by instances(), but
must be understood by C<status_one()>, and C<pidfile()> and/or C<stop_one()>.

=cut

sub to_stop() {
}


sub ddump {
   my ($self, @obj) = @_;

   my $var = 'var0';
   return
      Data::Dumper->new([ @obj ],
                        [ map { $var++ } @obj ]
                     )->Terse(1)->Indent(0)->Dump;
}

sub _getpid {
   my ($self, $file) = @_;

   open(my $fh, '<', $file);
   my $text = do { local $/; <$fh> };
   close($fh);
   chomp($text);

   return $text;
}

=back

=head1 AUTHOR

Jeremy Brinkley, E<lt>jbrinkley@proofpoint.comE<gt>

=cut

1;
