module main

import os
import regex
import net.http
import x.json2

const vpm_hosts = ['https://vpm.vlang.io', 'https://vpm.url4e.com']
const mirror_target = 'mirror'
const is_ci = os.getenv_opt('CI') != none
const term_width = 60
const max_concurrent_downloads = 8

fn main() {
	unbuffer_stdout()
	println('Getting all packages...')
	packages := get_packages()!
	println('Found ${packages.len} packages!')

	os.mkdir_all(mirror_target)!

	// Channel to receive download results
	results := chan DownloadResult{cap: packages.len}

	// Semaphore to limit concurrent downloads
	mut sem := chan int{cap: max_concurrent_downloads}
	for _ in 0 .. max_concurrent_downloads {
		sem <- 1
	}

	// Spawn download tasks
	for i, package in packages {
		spawn download_worker(package, i, packages.len, sem, results)
	}

	// Collect results
	mut failed := 0
	for _ in 0 .. packages.len {
		result := <-results
		if result.err != '' {
			failed++
			eprintln('Error: ${result.err}')
		} else if !is_ci {
			print('[${result.index}/${packages.len}] ${result.package#[..term_width]}${' '.repeat(term_width - result.package.len)}\r')
		}
	}
	println('')

	if failed > 0 {
		eprintln('Failed to mirror ${failed} packages.')
	}

	mirrored_packages := os.ls(mirror_target)!

	// If the upstream freaks out and mass deletes packages, don't delete them in the mirror
	// 10% seems like a sane limit!
	if packages.len > mirrored_packages.len * 0.9 {
		for mirrored in mirrored_packages {
			if mirrored[..mirrored.len - 5] in packages {
				continue
			}
			println('Removing removed package ${mirrored}')
			os.rm(mirrored)!
		}
	}
}

fn get_packages() ![]string {
	// there is no API for getting all packages, use the HTML instead
	res := http_get('/search')!

	mut packages_re := regex.regex_opt(r'/packages/[^"]+')!
	packages := packages_re.find_all_str(res.body)

	return packages.map(it[10..])
}

struct DownloadResult {
	package string
	index   int
	err     string
}

fn download_worker(package string, index int, total int, sem chan int, results chan DownloadResult) {
	// Acquire semaphore slot
	_ := <-sem
	defer { sem <- 1 }

	if is_ci {
		println('Downloading ${package} (${index}/${total})')
	}

	mirror_package(package) or {
		results <- DownloadResult{
			package: package
			index: index
			err: '${err}'
		}
		return
	}

	results <- DownloadResult{
		package: package
		index: index
		err: ''
	}
}



fn mirror_package(name string) ! {
	mirror_file := os.join_path(mirror_target, '${name}.json')
	upstream := http_get('/api/packages/${name}')!

	if !upstream.body.starts_with('{') {
		return error('Package not found')
	}

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
