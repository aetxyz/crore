crore(1)

# NAME

*crore* - cron daemon

# DESCRIPTION

*crore* is a lightweight cron daemon, focused on (1) running without a
filesystem, (2) performance, and (3) minimizing system resource usage, in that
order.

*crore* is single-threaded, stays off the heap as much as it can, only reads
the filesystem at init to load the crontab (and even this is optional) and then
never again touches the disk. It only keeps enough in memory to know what and
when to execute, and it only ever has one child process executing at a time.
Its method of resolving the next execution time of a task avoids exhaustively
iterating through upcoming datetimes (except in some edge cases regarding
weekday resolution, for now) in an effort to reduce the load required when tasks
are rescheduled.

*crore* is extensible! See *HOOKS*.

# USAGE

*crore* accepts an optional single positional argument: a path to a config file.
This path can be relative to the current directory or fully qualified. If you
don't provide this, verbosity is set to maximum and it will look for its
crontab at _$HOME/.config/crore/tab_.

Once started, *crore* will find and parse the crontab, failing if it can't find
anything to schedule. At the default verbosity, it will also report all the
cron expressions, associated commands, and environment variables it sees, then
sleep until the next scheduled job triggers. You can use this output to confirm
your setup.

Once started, *crore* does not look at the crontab again. You must restart
*crore* for it to reflect changes that are made to the crontab.

It is possible to run *crore* without a crontab, or even a config file, with
sufficiently comprehensive command line input. In this way you can run *crore*
without touching the local filesystem if you wish.

*crore* does not fork itself into the background. Daemonize it however you
wish. If you use *runit*(8) or OpenRC, you can use a provided configuration if
you like.

# CONFIGURATION

Options can be loaded from the config file at a path indicated in the first
positional argument. By default, it looks in _$HOME/.config/crore/tab_. Most
options can also be selected via flags. In this section, the flag syntax is
separated by a "|" character from the config file syntax.

If you select the same option with both the config file and flags in a
conflicting manner, the content of the flags will take precedence over the
config file.

The config file syntax delimits the key and value parameters with an equal sign
separated by one space on each side, precisely as shown. This is true in all
cases. Some config parameters do not require a value; these are shown without
a value.

*-a* _command_ | *after* = _command_
	Run the given command immediately after each job. See *HOOKS*.

*-b* _command_ | *before* = _command_
	Run the given command immediately before each job. See *HOOKS*.

*-e* _key=val_ | *KEY* = _value_
	Set the environment variable *KEY* to the specified _value_. You can
	set any key as long as it does not have the same key as any config
	parameter in this document. At the command prompt, you can provide this
	flag multiple times with different keys. If you provide the same key,
	the key provided last takes precedence. Keys do not have to be in
	uppercase; the parser simply interprets anything other than a valid
	config option as an environment variable.

*-l* | *legacy*
	Sets *crore* to legacy mode. In legacy mode, (1) all output is
	intercepted by *crore*, buffered, assumed to indicate error, and
	logged. Also, (2) exit codes are ignored. Be mindful of how much output
	you want to buffer in legacy mode, as *crore* does not do a heap
	allocation for the data it intercepts. This mode exists to provide a
	cron interface more in line with other implementations.

*-n* | *notabfile*
	Tells *crore* not to try to find a tabfile. If set, you must provide
	expressions manually via *-x*.

*-p* | *private*
	Set the log mode to not log any env vars or commands. Output from
	commands is still logged. Use this if you are, for example, passing
	passwords to a cronjob in plaintext or otherwise do not want your
	commands broadcast to stdout.

*-s* | *silent*
	Set the log mode to log nothing. Fatal errors may still cause output.

*-t* _tabfile_ | *tabfile*
	Look for the crontab file at the provided path. The path can be
	relative to the current directory, or absolute.

*-v*
	Print the current version and exit.

*-x* _expression_
	Provide an additional cron expression in the form of a string, to be
	parsed in the normal way as though it were a line in a crontab file.
	If you provide *-n* | *notabfile*, this is the only way to provide
	expressions, but you can also provide additional expressions this way
	that are not expressed in your crontab in an additive manner.

# BEHAVIOR

*crore* continues operating indefinitely once started, as long as it has at
least one pending cronjob. Because it accepts cron expressions at init and
never again, this means it either fails immediately at init (if it has no
expressions) or runs indefinitely.

At init, depending on verbosity, *crore* is able to log all expressions and
environment variables it sees, as well as the next timestamp at which each is
to be executed. *crore* then sleeps until the earliest such execution time and
informs the user of the length of that sleep. When it wakes up, it will log
(again, depending on verbosity) which job or how many jobs it woke for,
execute jobs as needed, re-queue them, sleep, and repeat.

Cronjobs are executed sequentially, never simultaneously. This means a long-
running cronjob can block other ones from executing on time. If this happens,
they will be executed immediately upon completion of the long-running job. If a
late job is completed late, it will be rescheduled relative to the current
time, which may make it run less frequently than expected. These are intended
compromises to achieve a low-footprint design, but there is a planned config
option to allow simultaneous execution. In the meantime, intensive users of
*crore* are encouraged to avoid scheduling repeated long-running tasks close to
each other.

## Deviations From Other Cron Implementations

- As noted above, *crore* reads its crontab once at init and never again, so it
  must be restarted to pick up changes to it.
- *crore* interprets all times in UTC. This is true even if the *legacy* option
  is enabled.
- *crore* looks for its crontab at a nonstandard location by default.
- *crore* doesn't expect programs to stay quiet.
- *crore* does not send mail, interact with pam, or otherwise do anything with
  the system behind the scenes other than what is precisely indicated in the
  tab and config. If you need such features, you can use hooks.

# HOOKS

*crore* has a concept of hooks, which are commands run before and after each
cron command. There are two types of hooks available: (1) before, and (2) after.
Each of these is executed immediately adjacent to each cronjob.

If multiple jobs are set to execute at the same time, these commands will be
executed prior to each of these in sequence. For example, if there is a
_before_ hook and an _after_ hook set and two scheduled tasks, the execution
order would be:

. _before_ command
. first scheduled job
. _after_ command
. _before_ command
. second scheduled job
. _after_ command

For your optional use, certain environment variables are inserted into the
execution environment of commands executed as hooks. All hooks have:

*CRORE_COMMAND*
	The command associated with the cronjob we're hooking onto.

The _after_ hooks also have:

*CRORE_DURATION*
	The amount of time in integer microseconds that the cronjob ran before
	exiting.

*CRORE_RESULT*
	The outcome of the cronjob we're hooking onto. In normal mode, this
	equals the exit code or signal code of the cron command. In legacy
	mode, this equals the stderr output from the cron command, if any.

*crore* does not log the outcome of hooks themselves, although in non-silent
logging modes it will log appropriately that it is executing them.

# EXAMPLES

For example configs, see the _examples_ directory in the project repository.

# CONTRIBUTING

The *crore* author encourages constructive feedback, feature requests, and
patchsets submitted to him personally.
