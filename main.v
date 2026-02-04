module main

import os
import regex
import net.http
import x.json2

const vpm_hosts = ['https://vpm.vlang.io', 'https://vpm.url4e.com']
const mirror_target = 'mirror'
const is_ci = os.getenv_opt('CI') != none
const term_width = 60

fn main() {
	unbuffer_stdout()
	println('Getting all packages...')
	packages := get_packages()!
	println('Found ${packages.len} packages!')

	os.mkdir_all(mirror_target)!

	mut failed := 0
	for i, package in packages {
		if is_ci {
			println('Downloading ${package} (${i}/${packages.len})')
		} else {
			print('[${i}/${packages.len}] ${package#[..term_width]}${' '.repeat(term_width - package.len)}\r')
		}
		mirror_package(package) or {
			failed++
			eprintln('Error: ${err}')
		}
	}

	if failed > 0 {
		eprintln('Failed to mirror ${failed} packages.')
	}

	mirrored_packages := os.ls(mirror_target)!
	for mirrored in mirrored_packages {
		if mirrored[..mirrored.len - 5] in packages {
			continue
		}
		println('Removing removed package ${mirrored}')
		os.rm(mirrored)!
	}
}

fn get_packages() ![]string {
	// there is no API for getting all packages, use the HTML instead
	res := http_get('/search')!

	mut packages_re := regex.regex_opt(r'/packages/[^"]+')!
	packages := packages_re.find_all_str(res.body)

	return packages.map(it[10..])
}


fn mirror_package(name string) ! {
	mirror_file := os.join_path(mirror_target, '${name}.json')
	upstream := http_get('/api/packages/${name}')!

	parsed := json2.decode[json2.Any](upstream.body)!
	mut top := parsed.as_map()
	top['nr_downloads'] = -1

	os.write_file(mirror_file, json2.encode(parsed, prettify: true))!
}

fn http_get(path string) !http.Response {
	for i in 0 .. vpm_hosts.len * 3 {
		target := vpm_hosts[i % vpm_hosts.len]
		url := target + path
		res := http.get(url) or {
			eprintln('failed to GET ${url}: ${err}')
			continue
		}
		status := res.status()
		if status.is_success() {
			return res
		}
		eprintln('failed to GET ${url}: ${status.int()} ${status.str()}')
	}

	return error('all retry attempts failed')
}
