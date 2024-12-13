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
use os;
use os::exec;
use shlex;
use strings;
use time;

use config;
use cron;

export fn main() void = {
	fmt::println("crore is GPLv3 free software; code is available from https://git.context.town/crore")!;
	const conf: config::config = match (config::build()) {
		case let c: config::config => yield c;
		case let i: int => {
			if (i < 0) {
				fmt::fatal("invalid command line input");
			} else {
				fmt::fatalf("invalid config (line {})", i + 1);
			};
		};
	};

	let lines = conf.exprs;

	if (!conf.no_tab) {
		let tab_loc = conf.tab;
		let needs_free = false;
	
		if (len(tab_loc) == 0) {
			const env_home = os::getenv("HOME");
			if (env_home is str) {
				tab_loc = strings::concat(
					env_home: str, "/.config/crore/tab",
				);
				needs_free = true;
			};
		};

		if (conf.verbosity > config::verbosity::SILENT) {
			fmt::printfln("crore: reading tab at {}", tab_loc)!;
		};

		append(lines, config::parse_file(tab_loc)...);

		if (needs_free) {
			free(tab_loc);
		};
	};

	let jobs: []cron::cronjob = [];

	for (let i = 0z; i < len(lines); i += 1) {
		const item_raw = lines[i];

		if (len(item_raw) == 0 || strings::hasprefix(item_raw, '#')) {
			continue;
		};

		match (cron::new(item_raw)) {
			case let c: cron::cronjob => {
				append(jobs, c);
			};
			case errors::invalid => {
				fmt::fatalf(
					"invalid cron expression (line {})",
					i + 1
				);
			};
			case shlex::syntaxerr => {
				fmt::fatalf(
					"invalid sh command (line {})",
					i + 1
				);
			};
		};
	};
	free(lines);

	if (len(jobs) == 0) {
		fmt::fatal("crore: tab is empty");
	};

	if (conf.verbosity == config::verbosity::NORMAL) {
		for (let i = 0z; i < len(jobs); i += 1) {
			cron::print(&jobs[i]);
		};
	};

	if (conf.verbosity > config::verbosity::SILENT) {
		fmt::println("crore: tab is good")!;
	};

	cron::serve(jobs, &conf);
};
