// Copyright (C) 2023-2025 Adam Train
// 
// This file is part of crore.
// 
// crore is free software: you can redistribute it and/or modify it under the
// terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later
// version.
// 
// crore is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
// A PARTICULAR PURPOSE. See the GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License along with
// crore. If not, see <https://www.gnu.org/licenses/>.

use os::exec;
use fmt;
use strconv;
use strings;
use time;

use config;

// Continuously sleeps until the next time a cronjob is scheduled to trigger,
// executes the relevant jobs, reschedules them, and goes back to sleep.
// Additional params come from config: verbosity and legacy mode (see
// run_legacy() for details).
export fn serve(jobs: []cronjob, conf: *config::config) never = {
	const now = unix_now();
	for (true) {
		sleep(now, jobs, conf.verbosity);

		now = unix_now();
		let reschedulable: []*cronjob = [];

		// run all applicable jobs, then reschedule them all
		for (let i = 0z; i < len(jobs); i += 1) {
			if (jobs[i].next_run <= now) {
				if (conf.legacy) {
					run_legacy(&jobs[i], conf);
				} else {
					run(&jobs[i], conf);
				};
				append(reschedulable, &jobs[i]);
			};
		};

		for (let i = 0z; i < len(reschedulable); i += 1) {
			schedule(reschedulable[i])!;
		};

		free(reschedulable);
	};
};

// Executes the command associated with the cronjob, logging nonzero result.
fn run(j: *cronjob, conf: *config::config) void = {
	if (len(conf.before) > 0) {
		run_before_hook(conf);
	};

	const (res, dur) = exec(j.cmd, &conf.envs);
	if (res is exec::error) {
		fmt::println(exec::strerror(res: exec::error))!;
		return;
	};
	const res = res: exec::status;
	const exit_s = exec::exit(&res);

	const cmdstr = cmd_str(j);
	defer free(cmdstr);

	let res_int = 0;
	match (exit_s) {
		case let s: exec::exited => {
			res_int = s: int;
			if (s: int != 0 &&
				conf.verbosity > config::verbosity::SILENT
			) {
				fmt::printfln(
					"cronjob exited status {} ({})",
					s: int,
					cmdstr,
				)!;
			};
		};
		case let s: exec::signaled => {
			res_int = s: int;
			if (conf.verbosity > config::verbosity::SILENT) {
				fmt::printfln(
					"cronjob exited from signal {} ({})",
					res_int,
					cmdstr,
				)!;
			};
		};
	};

	if (len(conf.after) > 0) {
		run_after_hook(conf, strconv::itos(res_int), dur);
	};
};

// Executes the command associated with the cronjob in legacy mode. We capture
// the stdout and stderr of the proc, expecting nothing. If we get anything, we
// assume an error has occurred, log accordingly, then let the output continue
// along. Exit statuses are ignored.
//
// This is a somewhat arbitrary behavior that is designed specifically for
// compatibility with the prevailing way of doing cron.
//
// One layer deeper, this method calls exec::pipe(), which is less portable than
// everything else in this program. Elsewhere, we test this method doesn't abort
// on the system before we let the user select legacy mode.
//
// We also keep off the stack but intercept all stdout and stderr from the
// underlying process calls, so be mindful if anything logs a heavy amount.
//
// Seriously, just don't use this.
fn run_legacy(j: *cronjob, conf: *config::config) void = {
	if (len(conf.before) > 0) {
		run_before_hook(conf);
	};

	const (out, dur) = exec_legacy(j, &conf.envs);
	if ((len(out.0) == 0 && len(out.1) == 0) ||
		conf.verbosity == config::verbosity::SILENT) {
		
		return;
	};

	if (conf.verbosity == config::verbosity::PRIVATE) {
		fmt::println("crore: got non-empty output (check logs)")!;
		return;
	};

	let cmdstr = cmd_str(j);
	defer free(cmdstr);

	fmt::printfln(
		"crore: got non-empty output from `{}`:",
		cmdstr,
	)!;
	if (len(out.0) > 0) {
		fmt::println("stdout:", out.0...)!;
	};
	if (len(out.1) > 0) {
		fmt::println("stderr:", out.1...)!;
	};

	if (len(conf.after) > 0) {
		run_after_hook(conf, out.1, dur);
	};
};

fn run_before_hook(conf: *config::config) void = {
	if (conf.verbosity > config::verbosity::SILENT) {
		fmt::println("crore: before-hook")!;
	};

	let hook_envs: []config::keyval = [config::keyval {
		k = "CRORE_COMMAND",
		v = strings::join(" ", conf.before...),
	}];
	defer free(hook_envs[0].v);
	
	const ignored = exec(conf.before, &conf.envs, &hook_envs);
};

fn run_after_hook(conf: *config::config, r: str, dur: time::duration) void = {
	if (conf.verbosity > config::verbosity::SILENT) {
		fmt::println("crore: after-hook")!;
	};
	let hook_envs: []config::keyval = [
		config::keyval {
			k = "CRORE_COMMAND",
			v = strings::join(" ", conf.after...),
		},
		config::keyval {
			k = "CRORE_RESULT",
			v = r,
		},
		config::keyval {
			k = "CRORE_DURATION",
			v = strconv::i64tos(dur / 1000),
		},
	];
	defer free(hook_envs[0].v);

	const ignored = exec(conf.after, &conf.envs, &hook_envs);
};

// Sleeps until the first cronjob in the list must execute. Logs as it goes.
// Uses the `next_run` field of the cronjobs for convenience, NOT the cron
// expressions.
// 
// If the next execution time of any job is indicated in the past, returns
// immediately without logging.
fn sleep(now: i64, jobs: []cronjob, v: config::verbosity) void = {
	let earliest = jobs[0];
	let earliest_count = 0;

	for (let i = 0z; i < len(jobs); i += 1) {
		if (jobs[i].next_run < earliest.next_run) {
			earliest = jobs[i];
			earliest_count = 1;
		} else if (jobs[i].next_run == earliest.next_run) {
			earliest_count += 1;
		};
	};

	const secs = earliest.next_run - now;
	if (secs <= 0) {
		return;
	};

	switch (v) {
		case config::verbosity::SILENT => {
			time::sleep(secs * 1e9);
		};
		case config::verbosity::PRIVATE => {
			fmt::printfln("crore: sleeping {}s", secs)!;
			time::sleep(secs * 1e9);
			fmt::println("crore: awake")!;
		};
		case config::verbosity::NORMAL => {
			let cmd = strings::join(" ", earliest.cmd...);
			if (earliest_count > 1) {
				free(cmd);
				cmd = fmt::asprintf(
					"{} coincident jobs", earliest_count
				);
			};

			fmt::printfln(
				"crore: sleeping {}s until: {}", secs, cmd
			)!;

			time::sleep(secs * 1e9);

			fmt::printfln("crore: awake for: {}", cmd)!;

			free(cmd);
		};
	};
};

// Returns the current time as a Unix timestamp.
fn unix_now() i64 = {
	return time::unix(time::now(time::clock::REALTIME));
};
