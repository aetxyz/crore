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
use strconv;
use strings;

export type term = struct {
	min: int,
	max: int,
	step: int
};

// Parses a single positional cron term into a collection of simplistic terms,
// such that the number of terms is the number of commas appearing in the cron
// term plus one. The caller must free the returned value.
export fn parse_term(in: str, min: int, max: int) ([]term | errors::invalid) = {
	let output: []term = [];

	const comps = strings::split(in, ",");
	defer free(comps);
	
	for (let i = 0z; i < len(comps); i += 1) {
		append(output, parse_single_term(comps[i], min, max)?);
	};

	return output;
};

fn parse_single_term(in: str, min: int, max: int) (term | errors::invalid) = {
	if (in == "*") {
		return term {
			min = min,
			max = max,
			step = 1
		};
	};

	let out = term {
		min = 0,
		max = -1,
		step = 1
	};

	// The regex implementation is unexpectedly limited (so far), so we use
	// manual string splitting. Hopefully we can use one regex someday.
	const subbed = strings::replace(in, "*", "0");
	const input = strings::split(subbed, "/");
	const res = strings::split(input[0], "-");

	defer free(subbed);
	defer free(input);
	defer free(res);

	if (len(res) > 0) {
		let single = strconv::stoi(res[0]);
		if (single is int) {
			out.min = single as int;
			out.max = single as int;
		} else if (res[0] == "*") {
			out.min = min;
			out.max = max;
		} else {
			return errors::invalid;
		};
	} else {
		return errors::invalid;
	};

	// range cases, e.g. 5-10, 5-10/2, *-8/2 (nonstandard but fine), etc.
	// (in the case of simple range e.g. 5-10, fifth match is empty string)
	if (len(res) == 2) {
		let end = strconv::stoi(res[1]);
		if (end is int) {
			out.max = end as int;
		} else {
			return errors::invalid;
		};
	};

	// any case with step value
	if (len(input) == 2) {
		if (len(input[1]) > 0) {
			let step = strconv::stoi(input[1]);
			if (step is int) {
				out.step = step as int;
			} else {
				return errors::invalid;
			};

			// account properly for 5/5 etc.
			if (out.max == -1 || out.max == out.min) {
				out.max = max;
			};
		} else {
			return errors::invalid;
		};
	};

	if (out.min < min || out.max > max || min > max || out.step == 0) {
		return errors::invalid;
	};
	
	return out;
};

@test fn parse_term() void = {
	let cases: [](str, term) = [
		("5", term {
			min = 5,
			max = 5,
			step = 1
		}),
		("5-10", term {
			min = 5,
			max = 10,
			step = 1
		}),
		("5/5", term {
			min = 5,
			max = 59,
			step = 5
		}),
		("10-18/5", term {
			min = 10,
			max = 18,
			step = 5
		}),
		("0", term {
			min = 0,
			max = 0,
			step = 1
		}),
		("6/1", term {
			min = 6,
			max = 59,
			step = 1
		}),
		("*", term {
			min = 0,
			max = 59,
			step = 1
		}),
		("1/5", term {
			min = 1,
			max = 59,
			step = 5
		}),
		("*/5", term {
			min = 0,
			max = 59,
			step = 5
		}),
		("*-8/2", term {
			min = 0,
			max = 8,
			step = 2
		})
	];

	for (let i = 0z; i < len(cases); i += 1) {
		let parsed = parse_single_term(cases[i].0, 0, 59)!;

		fmt::printfln(
			"case {}, parsed: min {} max {} step {}",
			cases[i].0, parsed.min, parsed.max, parsed.step
		)!;
		
		assert(parsed.min == cases[i].1.min);
		assert(parsed.max == cases[i].1.max);
		assert(parsed.step == cases[i].1.step);
	};
};
