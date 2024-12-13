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

use errors;
use fmt;
use io;
use os;
use os::exec;
use shlex;
use sort;
use sort::cmp;
use strconv;
use strings;
use time;
use time::chrono;
use time::date;

use config;

// A single line of a crontab; a command to be executed on a schedule.
export type cronjob = struct {
	expression: []str,
	next_run: i64, // epoch timestamp
	next_run_date: date::date,
	cmd: []str
};

// Creates a new cronjob based on the passed cron expression and command.
// Expects input in the form of a full cron line, i.e. `* * * * * /bin/sh`.
export fn new(s: str) (cronjob | errors::invalid | shlex::syntaxerr) = {
	const cron_item_split = strings::splitn(s, " ", 6);

	if (len(cron_item_split) != 6) {
		return errors::invalid;
	};

	let c = cronjob {
		expression = cron_item_split[0..5],
		cmd = shlex::split(cron_item_split[5])?,
		next_run = -1,
		next_run_date = date::nowutc(),
	};

	if (schedule(&c) is void) {
		return c;
	} else {
		return errors::invalid;
	};
};

// Schedules or reschedules the cronjob for the next applicable time, based on
// its cron expression. Will never fail if the cron expression is valid.
export fn schedule(j: *cronjob) (void | errors::invalid) = {
	match (next(j)) {
		case let n: date::date => {
			j.next_run_date = n;

			const d = date::asformat("%s", &n)!;
			j.next_run = strconv::stoi(d)!;
			free(d);
		};
		case => {
			return errors::invalid;
		};
	};
};

// Executes the command represented by the given args. The first arg is
// expected to be the path to the executable.
export fn exec(
	args: []str,
	envs: *[]config::keyval...
) ((exec::status | exec::error), time::duration) = {
	const cmd: exec::command = match (exec::cmd(args[0], args[1..]...)) {
		case let c: exec::command => yield c;
		case let err: exec::error => return (err, 0);
	};

	// set up env vars if any
	for (let i = 0z; i < len(envs); i += 1) {
		for (let j = 0z; j < len(envs[i]); j += 1) {
			exec::setenv(&cmd, envs[i][j].k, envs[i][j].v)!;
		};
	};

	const start = time::now(time::clock::MONOTONIC);
	const proc: exec::process = match (exec::start(&cmd)) {
		case let p: exec::process => yield p;
		case let err: exec::error => return (err, 0);
	};

	let out = exec::wait(&proc);
	return (out, time::diff(start, time::now(time::clock::MONOTONIC)));
};

// Executes the command attached to the cronjob in legacy mode (see
// run_legacy() for details). The first return value is stdout, then stderr.
export fn exec_legacy(
	j: *cronjob, envs: *[]config::keyval...
) ((str, str), time::duration) = {
	const cmd: exec::command = match (exec::cmd(j.cmd[0], j.cmd[1..]...)) {
		case let c: exec::command => yield c;
		case let err: exec::error => {
			return (("", exec::strerror(err)), 0);
		};
	};

	// set up env vars if any
	for (let i = 0z; i < len(envs); i += 1) {
		for (let j = 0z; j < len(envs[i]); j += 1) {
			exec::setenv(&cmd, envs[i][j].k, envs[i][j].v)!;
		};
	};

	// intercept all output
	let p = exec::pipe();
	exec::addfile(&cmd, os::stdout_file, p.1);
	let q = exec::pipe();
	exec::addfile(&cmd, os::stderr_file, q.1);

	const start = time::now(time::clock::MONOTONIC);
	const proc: exec::process = match (exec::start(&cmd)) {
		case let p: exec::process => yield p;
		case let err: exec::error => {
			return (("", exec::strerror(err)), 0);
		};
	};

	io::close(p.1)!;
	io::close(q.1)!;

	let stdout_data = io::drain(p.0)!;
	let stderr_data = io::drain(q.0)!;

	defer free(stdout_data);
	defer free(stderr_data);

	io::close(p.0)!;
	io::close(q.0)!;

	let ignored = exec::wait(&proc);
	let dur = time::diff(start, time::now(time::clock::MONOTONIC));

	let b: []u8 = [];
	let d: []u8 = [];
	if (len(stdout_data) > 0) {
		append(b, stdout_data...);
	};

	if (len(stderr_data) > 0) {
		append(d, stderr_data...);
	};

	let out = (strings::fromutf8(b), strings::fromutf8(d));
	if (!(out.0 is str) || !(out.1 is str)) {
		return (("", "output not valid utf-8"), dur);
	};

	return ((out.0: str, out.1: str), dur);
};

// Prints the contents of the cronjob.
export fn print(j: *cronjob) void = {
	const s = date::asformat("%a %Y-%m-%dT%T%z", &j.next_run_date)!;
	const expr = strings::join(" ", j.expression...);
	const cmd = strings::join(" ", j.cmd...);
	
	defer free(s);
	defer free(expr);
	defer free(cmd);

	fmt::printfln(
		"crore: expr: {}, cmd: {}, next: {} ({})",
		expr, cmd, j.next_run, s,
	)!;
};

// Reports the next datetime, in UTC, at which the cronjob will trigger.
export fn next(j: *cronjob) (
	date::date | date::error | errors::invalid | chrono::discontinuity
) = {
	const minutes = parse_term(j.expression[0], 0, 59)?;
	const hours = parse_term(j.expression[1], 0, 23)?;
	const days = parse_term(j.expression[2], 1, 31)?;
	const months = parse_term(j.expression[3], 1, 12)?;
	const dows = parse_term(j.expression[4], 0, 6)?;

	defer free(minutes);
	defer free(hours);
	defer free(days);
	defer free(months);
	defer free(dows);
	
	const now = date::nowutc();

	const next_date = next_applicable_date(&now, months, days, dows);

	return next_applicable_time(&now, &next_date, hours, minutes);
	
};

// condense returns the next applicable number from a set of terms, and is a
// nasty one because it has the potential to wrap around. The second result is
// a bool indicating whether we wrapped around such that the next applicable
// value is lower than the input value (i.e. we are at hour 23 and matched
// after midnight).
fn condense(
	t: []term,
	global_min: int,
	global_max: int,
	in: int,
	include_current: bool
) (int, bool) = {

	let outs: []int = [];
	defer free(outs);

	for (let i = 0z; i < len(t); i += 1) {
		append(outs, next_applicable(t[i], in, include_current));
	};

	if (!include_current) {
		in += 1;
		if (in > global_max) {
			in = global_min;

			let lowest = t[0].min;
			for (let i = 0z; i < len(t); i += 1) {
				if (t[i].min < lowest) {
					lowest = t[i].min;
				};
			};

			return (lowest, true);
		};
	};

	// get the lowest that is higher than input value,
	// then fall back to absolute lowest if not possible.
	let lowest = 999;
	let low_wraps_around = true;

	for (let i = 0z; i < len(outs); i += 1) {
		if (outs[i] < in) {
			continue;
		};
	
		if (outs[i] < lowest) {
			lowest = outs[i];
			low_wraps_around = false;
		};
	};

	if (!low_wraps_around) {
		return (lowest, false);
	};
	
	lowest = t[0].min;
	for (let i = 0z; i < len(t); i += 1) {
		if (t[i].min < lowest) {
			lowest = t[i].min;
		};
	};

	return (lowest, true);
};

// Returns the value closest to in that matches the term. It will "wrap around"
// if necessary, i.e. if the term matches `1` only and `in == 4`.
fn next_applicable(t: term, in: int, include_current: bool) int = {
	if (!include_current) {
		in += 1;
		if (in > t.max) {
			in = t.min;
		};
	};

	if (in <= t.min || in > t.max) {
		return t.min;
	};

	for (let i = t.step; i <= t.max; i += t.step) {
		if (t.step > 1 && i >= in && i % t.step == 0) {
			return i;
		};

		if (i == in) {
			return i;
		};
	};

	return t.min;
};

fn next_applicable_date(
	now: *date::date, m: []term, d: []term, dow: []term
) date::date = {
	let cur_year = date::year(now);
	let cur_doy = date::yearday(now);

	let (cand_day, day_wrapped) = condense(d, 1, 31, date::day(now), true);
		
	let (cand_month, month_wrapped) = condense(
		m, 1, 12, date::month(now), !day_wrapped
	);

	// in cron, 0=Sun; in Hare, 0=Mon
	const dow_list = to_slice(dow, -1);
	defer free(dow_list);

	let candidate = date::new(
		time::chrono::UTC,
		0,
		cur_year,
		cand_month,
		cand_day,
	)!;

	// failsafe to prevent matching in the past of current year
	// TODO: This can be reworked.
	if (date::yearday(&candidate) < cur_doy) {
		cand_month = condense(m, 1, 12, 1, true).0;
		cand_day = condense(d, 1, 31, 1, true).0;

		candidate = date::new(
			time::chrono::UTC,
			0,
			cur_year + 1,
			cand_month,
			cand_day,
		)!;
	};

	if (len(dow_list) == 0) {
		return candidate;
	};

	// TODO: Make this more efficient. Weekday params that are
	// restrictive with month and day are silly and this really
	// shouldn't have to iterate more than a few times in reality!
	for (true) {
		const cand_dow = date::weekday(&candidate);

		for (let i = 0z; i < len(dow_list); i += 1) {
			if (
				dow_list[i] == cand_dow &&
				is_applicable(m, date::month(&candidate)) &&
				is_applicable(d, date::day(&candidate))
			) {
				return candidate;
			};
		};

		candidate = date::reckon(
			candidate,
			0,
			date::period {
				days = 1,
				...
			},
		);
	};
};

fn next_applicable_time(
	now: *date::date, cur: *date::date, h: []term, m: []term
) date::date = {
	let cur_hr = 0;
	let cur_min = 0;
	let cur_day = date::day(cur);

	let cand_min = condense(m, 0, 59, cur_min, true).0;
	let cand_hour = condense(h, 0, 23, cur_hr, true).0;

	if (date::year(now) == date::year(cur) &&
		date::month(now) == date::month(cur) &&
		date::day(now) == date::day(cur))
	{
		const (new_min, min_wrapped) = condense(
			m, 0, 59, date::minute(now), false
		);
		const (new_hour, hour_wrapped) = condense(
			h, 0, 23, date::hour(now), !min_wrapped
		);

		cand_min = new_min;
		cand_hour = new_hour;

		if (hour_wrapped) {
			cur_day += 1;
			cand_min = condense(m, 0, 59, cur_min, true).0;
			cand_hour = condense(h, 0, 23, cur_hr, true).0;
		};
	};

	return date::new(
		time::chrono::UTC,
		0,
		date::year(cur),
		date::month(cur),
		cur_day,
		cand_hour,
		cand_min
	)!;
};

// Returns a bool indicating whether the given `in` value is applicable to any
// passed term.
fn is_applicable(terms: []term, in: int) bool = {
	for (let i = 0z; i < len(terms); i += 1) {
		const t = terms[i];
		if (in > t.max || in < t.min) {
			continue;
		};

		if (in == t.min || in % t.step == 0) {
			return true;
		};
	};

	return false;
};

// Returns slices for nums that meet the criteria for the term. Empty list
// means no restrictions exist based on this term. (The logic to check for
// this is currently lazy and only applies to days of week.)
fn to_slice(terms: []term, shift: int) []int = {
	let out: []int = [];

	for (let t = 0z; t < len(terms); t += 1) {
		if (
			terms[t].min == 0 &&
			terms[t].max == 6 &&
			terms[t].step == 1
		) {
			continue;
		};
	
		if (terms[t].min < terms[t].step) {
			append(out, terms[t].min);
		};

		for (
			let i = terms[t].step;
			i <= terms[t].max;
			i += terms[t].step) 
		{
			if (i < terms[t].min) {
				continue;
			};

			let n = i + shift;

			if (n < terms[t].min) {
				n = terms[t].max - (terms[t].min - n);
			} else if (n > terms[t].max) {
				n = terms[t].min + (n - terms[t].max);
			};

			append(out, n);
		};
	};

	return out;
};

// Returns a string representing the cronjob command.
// The caller must free the returned value.
fn cmd_str(j: *cronjob) str = {
	return strings::join(" ", j.cmd...);
};

@test fn cronjob_parsing() void = {
	// Because the current time is always changing, manual inspection
	// is best for testing these. This is why this test prints.
	const cases: []str = [
		"* * * * * /bin/sh",
		"*/2 * * * * /bin/sh",
		"* 2 * * * /bin/sh",
		"8 * * * * /bin/sh",
		"9-18 * * * * /bin/sh",
		"10-18,5 * * * * /bin/sh",
		"54,10-18 * * * * /bin/sh",
		"4 5 6 7 4 /bin/sh",
		"* * 23 12 3 /bin/sh"
		"8-18/4 * * * * /bin/sh",
		"8-18,5/2 * * * * /bin/sh",
		"5,8-18/5 * * * * /bin/sh",
		"4 5 6 7 4/2 /bin/sh",
		"0 0 1 1 6 /bin/sh",
	];

	for (let i = 0z; i < len(cases); i += 1) {
		let j = new(cases[i])!;
		fmt::printf("{}\n", cases[i])!;
		print(&j);
		fmt::println()!;
	};
};
