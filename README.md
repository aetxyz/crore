# crore

`crore` is a lightweight cron daemon written in less than 1400 lines of pure
Hare. It started as a fun way for me to learn Hare and has become my primary
cron daemon on Linux.

## Design Priorities

`crore` is designed to be:

* Run without a filesystem
* Fast
* As light on system resources as possible

In that order.

`crore` is single-threaded, stays off the heap as much as it can, only reads
the filesystem at init to load the crontab (and even this is optional) and then
never again touches the disk. It only keeps enough in memory to know what and
when to execute, and it only ever has one child process executing at a time.
Its method of resolving the next execution time of a task avoids exhaustively
iterating through upcoming datetimes (except in some edge cases regarding
weekday resolution, for now) in an effort to reduce the load required when tasks
are rescheduled.

On performance, it benefits from being written entirely with the Hare standard
library. At the moment, regexes are not used, but that may change in the future
depending on performance relative to the current technique of splitting strings
in various ways to parse expressions.

Of course, if a spawned process is intensive on system resources, `crore` is
unable to address that.

### Current Features

* Validates every cron expression at init and shows you next trigger time
* Tells you at init how long it'll be sleeping until the next scheduled job
* Sleeps until the next job must run and does not wake every minute
* Logs in a sensible, observable way about what it's doing
* Clear, intuitive way to set environment variables and optional verification
they have been understood
* Supports all major cron syntax features (e.g. ranges, steps, wildcards)
* All functionality is available via command line arguments, so filesystem
access is optional; alternatively, all functionality can be configured from a
config file if you prefer

`crore` also supports hooks, which are commands automatically run before and/or
after each cronjob executes. Using hooks, highly customized cron setups are
possible.

### Differences From Other Cron Implementations

* Executes jobs in one thread, sequentially, to minimize its footprint
* All times are in UTC all the time
* It functions from an in-memory copy of its crontab that it holds from when it
inits. It doesn't check again. This is deliberate to minimize interaction with
the filesystem.
* It looks in the current user's home directory (`$HOME/.config/crore/tab`) for
its crontab by default. You can make it look anywhere, though, or just feed it
expressions from the command line.

For those who want a more standard cron experience, there is a commented
`conf.trad.example` example config in the repo.

## Build

You'll need [Hare](https://harelang.org/installation/) installed.

```
make
sudo make install
```

Note: If you use my Makefile, this installs to `/usr/bin` by default so the
default `runit` configuration can see it. Adjust PREFIX if you don't want that.

You'll need to daemonize this yourself, however you prefer. On Void Linux I use
a simple runit config which is in the repo. If you use an applicable `runit`
setup with an `/etc/sv` directory, you can run `make install-runit` to put that
in place for you.

There is also a default OpenRC configuration for use with applicable systems.

See `crore(1)`.

## Benchmarking

This section is as of v0.1.2.

By my own tests conducted via `valgrind(1)`, on my x86_64 Linux computer on 13
Dec 2023, `crore` wants about 9.5 KiB plus ~0.5 KiB per expression, depending
on the length of the commands in each expression. At init, it allocates about
three times that on the heap before freeing it. Rescheduling a cronjob after
it executes causes a ~3KiB alloc which is then freed almost immediately.
As expected, the volume of cronjobs doesn't make that worse because the
rescheduling is done sequentially.

The steady-state footprint is therefore a max of, conservatively, 13 KiB plus
<1KiB per expression. Pretty nice!

For reference, this is about a 10x bigger footprint than `cronie`, but that's
the price we have to pay to run from memory. It's still vanishingly small! (The
price is also paid because of being able to report the next execution time of
things; without that, there'd be no reason to do anything but wake every minute
and execute whatever was applicable. There's certainly a performance trade-off
there, but I think it's worth it.)

## Contributing

I welcome patches or direct emails. Check out my lists or profile here on
sourcehut.
