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

use bufio;
use encoding::utf8;
use fmt;
use fs;
use errors;
use getopt;
use io;
use os;
use os::exec;
use shlex;
use strings;

export type verbosity = enum uint {
	SILENT = 0,
	PRIVATE = 1,
	NORMAL = 2,
};

export type config = struct {
	no_tab: bool,
	tab: str,
	verbosity: verbosity,
	envs: []keyval,
	exprs: []str,
	legacy: bool,
	before: []str,
	after: []str,
};

export type keyval = struct {
	k: str,
	v: str,
};

export fn build() (config | int) = {
	const cmd = getopt::parse(
		os::args,
		"cron daemon",
		('a', "command", "execute this after each job"),
		('b', "command", "execute this before each job"),
		('e', "key=val", "env vars for cron env"),
		('l', "legacy mode (see crore(1))"),
		('n', "no crontab file"),
		('p', "privacy-conscious logging"),
		('s', "silent"),
		('t', "tabfile", "path to crontab"),
		('v', "print version and exit"),
		('x', "expression", "extra cron expressions"),
		"configfile",
	);
	defer getopt::finish(&cmd);

	let out = config {
		legacy = false,
		no_tab = false,
		tab = "",
		verbosity = verbosity::NORMAL,
		envs = [],
		exprs = [],
		before = [],
		after = [],
	};

	let lines: []str = [];
	if (len(cmd.args) > 0) {
		lines = parse_file(cmd.args[0]);
	};

	for (let i = 0z; i < len(lines); i += 1) {
		if (len(lines[i]) == 0 || strings::hasprefix(lines[i], '#')) {
			continue;
		};

		const kv = parse_keyval(lines[i]);
	
		if (len(kv.k) == 0) {
			free(kv.v);
			return i: int;
		};

		switch (kv.k) {
			case "after" => {
				match (shlex::split(kv.v)) {
					case let c: []str => {
						out.after = c;
					};
					case => return i: int;
				};
			};
			case "before" => {
				match (shlex::split(kv.v)) {
					case let c: []str => {
						out.before = c;
					};
					case => return i: int;
				};
			};
			case "legacy" => {
				out.legacy = true;
				free(kv.v);
			};
			case "notabfile" => {
				out.no_tab = true;
				free(kv.v);
			};
			case "private" => {
				if (out.verbosity > verbosity::PRIVATE) {
					out.verbosity = verbosity::PRIVATE;
				};
				free(kv.v);
			};
			case "silent" => {
				out.verbosity = verbosity::SILENT;
				free(kv.v);
			};
			case "tabfile" => {
				out.tab = kv.v;
			};
			case => {
				// assume anything else is an env var
				append(out.envs, kv);
			};
		};
	};
	free(lines);

	for (let i = 0z; i < len(cmd.opts); i += 1) {
		const opt = cmd.opts[i];
		switch (opt.0) {
			case 'a' => {
				match (shlex::split(opt.1)) {
					case let c: []str => {
						out.after = c;
					};
					case => return i: int;
				};
			};
			case 'b' => {
				match (shlex::split(opt.1)) {
					case let c: []str => {
						out.before = c;
					};
					case => return i: int;
				};
			};
			case 'e' => {
				let kv = parse_keyval(opt.1);
				if (len(kv.k) == 0) {
					free(kv.v);
					return -1;
				};
				append(out.envs, kv);
			};
			case 'l' => {
				let test_pipe = os::exec::pipe();
				out.legacy = true;
			};
			case 'n' => {
				out.no_tab = true;
			};
			case 'p' => {
				if (out.verbosity > verbosity::PRIVATE) {
					out.verbosity = verbosity::PRIVATE;
				};
			};
			case 's' => {
				out.verbosity = verbosity::SILENT;
			};
			case 't' => {
				out.tab = opt.1;
			};
			case 'v' => {
				version();
			};
			case 'x' => {
				append(out.exprs, opt.1);
			};
			case => abort();
		};
	};

	if (out.verbosity > verbosity::SILENT) {
		for (let i = 0z; i < len(out.envs); i += 1) {
			let v = out.envs[i].v;
			if (out.verbosity <= verbosity::PRIVATE) {
				v = "{redacted}";
			};
			fmt::printfln(
				"crore: env: {}={}", out.envs[i].k, v
			)!;
		};

		if (len(out.before) > 0) {
			if (out.verbosity <= verbosity::PRIVATE) {
				fmt::println("crore: registered before-hook")!;
			} else {
				const b = strings::join(" ", out.before...);
				defer free(b);

				fmt::printfln(
					"crore: registered before-hook: {}",
					b,
				)!;
			};
		};

		if (len(out.after) > 0) {
			if (out.verbosity <= verbosity::PRIVATE) {
				fmt::println("crore: registered after-hook")!;
			} else {
				const a = strings::join(" ", out.after...);
				defer free(a);
				
				fmt::printfln(
					"crore: registered after-hook: {}",
					a,
				)!;
			};
		};

		fmt::println("crore: config is good")!;
	};
	return out;
};

// Gives the contents of a file, one string per line. The caller must free the
// return value. Aborts with fatal error if there is any read problem.
export fn parse_file(in: str) []str = {
	const f = match (os::open(in, fs::flag::RDONLY)) {
		case let f: io::file =>
			yield f;
		case let err: fs::error =>
			fmt::fatalf(
				"bad file at {}: {}",
				in,
				fs::strerror(err),
			);
	};

	let lines: []str = [];
	for (true) {
		const line = match (bufio::read_line(f)) {
			case let l: []u8 =>
				yield match (strings::fromutf8(l)) {
					case let s: str =>
						yield s;
					case let err: utf8::invalid =>
						fmt::fatalf(
							"bad file at {}: {}",
							in,
							utf8::strerror(err),
						);
				};
			case io::EOF =>
				break;
			case let err: io::error =>
				fmt::fatalf(
					"bad file at {}: {}",
					in,
					io::strerror(err),
				);
		};

		append(lines, line);
	};

	io::close(f)!;

	return lines;
};

// Turns `key = val` into a key-value struct. Blank on value without = sign
// separated by spaces.
// 
// The first such equal sign is the delimiter; the rest are treated as part of
// the value. The caller must free the returned `v` field on the struct.
fn parse_keyval(in: str) keyval = {
	const kv = strings::split(in, " = ");
	defer free(kv);

	let out = keyval {
		k = "",
		v = "",
	};

	if (len(kv) > 0) {
		out.k = kv[0];
	};

	if (len(kv) > 1) {
		out.v = strings::join(" = ", kv[1..]...);
	};

	return out;
};

fn version() never = {
	fmt::printfln("v0.2.2")!;
	os::exit(0);
};
