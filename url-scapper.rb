#!/usr/bin/env ruby

require 'fileutils'
require 'json'
require 'net/http'
require 'set'
require 'uri'
require 'logger'
require 'time'

CHROMECAST_HOME_URL = 'https://clients3.google.com/cast/chromecast/home'
USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
             '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'

def fetch_url(url_str, limit = 5)
  raise 'Too many HTTP redirects' if limit.zero?

  uri = URI.parse(url_str)
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = USER_AGENT

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 20, read_timeout: 30) do |http|
    http.request(request)
  end

  case response
  when Net::HTTPSuccess
    response.body
  when Net::HTTPRedirection
    fetch_url(response['location'], limit - 1)
  else
    raise "HTTP Error: #{response.code} #{response.message}"
  end
end

def unescape_js_single_quoted(raw)
  # Decode JavaScript hex (\x22), unicode (\u003d), and standard single-quote escapes
  raw.gsub(/\\(?:x([0-9a-fA-F]{2})|u([0-9a-fA-F]{4})|(['"\\\/bfnrt]))/) do
    if Regexp.last_match(1)
      [Regexp.last_match(1)].pack('H2')
    elsif Regexp.last_match(2)
      [Regexp.last_match(2).to_i(16)].pack('U')
    else
      case Regexp.last_match(3)
      when 'b' then "\b"
      when 'f' then "\f"
      when 'n' then "\n"
      when 'r' then "\r"
      when 't' then "\t"
      else Regexp.last_match(3)
      end
    end
  end
end

def extract_json_state(html)
  match = html.match(/JSON\.parse\('((?:\\.|[^'\\])*)'\)/)
  raise 'Could not find embedded JSON.parse() state in the HTML response.' unless match

  decoded_json_str = unescape_js_single_quoted(match[1])
  JSON.parse(decoded_json_str)
end

def normalize_high_res_url(url)
  url = "https:#{url}" if url.start_with?('//')
  base_url = url.split('=').first
  "#{base_url}=s3840-w3840-h2160-p-k-no-nd-mv"
end

def parse_entries(node, seen_urls = Set.new, results = [])
  case node
  when Array
    if node.length >= 2 && node[0].is_a?(String) && node[0].include?('googleusercontent.com')
      high_res_url = normalize_high_res_url(node[0])
      unless seen_urls.include?(high_res_url)
        seen_urls.add(high_res_url)
        attribution = node[1].is_a?(String) ? node[1].strip : 'Unknown'
        location = node.length > 2 && node[2].is_a?(String) ? node[2].strip : ''
        results << {
          'url' => high_res_url,
          'photographer' => attribution,
          'location' => location
        }
      end
    else
      node.each { |item| parse_entries(item, seen_urls, results) }
    end
  when Hash
    node.each_value { |value| parse_entries(value, seen_urls, results) }
  end

  results
end

def sanitize_filename(text, max_len = 60)
  cleaned = text.gsub(/[^\w\s-]/, '').strip.gsub(/[-\s]+/, '_')
  cleaned = cleaned[0, max_len]
  cleaned.empty? ? 'chromecast_bg' : cleaned
end

def url_id(url)
  File.basename(URI.parse(url.split('=').first).path)[0, 12]
end

def image_major_type?(response)
  (response.content_type || '').to_s.split(';').first.to_s.strip.downcase.split('/').first == 'image'
end

def normalize_etag(etag)
  value = etag.to_s.strip
  # ETags are quoted per RFC 7232; the enclosing quotes are not part of the value.
  value = value[1..-2] if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
  value.empty? ? nil : value
end

def validate_url(url_str, limit = 5)
  raise 'Too many HTTP redirects' if limit.zero?

  uri = URI.parse(url_str)
  request = Net::HTTP::Get.new(uri)
  request['User-Agent'] = USER_AGENT

  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 20, read_timeout: 30) do |http|
    http.request(request)
  end

  case response
  when Net::HTTPSuccess
    { ok: image_major_type?(response), etag: normalize_etag(response['ETag']) }
  when Net::HTTPRedirection
    validate_url(response['location'], limit - 1)
  else
    { ok: false, etag: normalize_etag(response['ETag']) }
  end
rescue StandardError => e
  $log.warn "Validation of #{url_str} failed: #{e.message}"
  { ok: false, etag: nil }
end

def load_existing_entries(path)
  return [] unless File.exist?(path)

  JSON.parse(File.read(path, encoding: 'UTF-8'))
rescue JSON::JSONError, EncodingError => e
  $log.warn "Could not parse existing #{path}: #{e.message}"
  []
end

def merge_entries(existing, scraped)
  merged = []
  seen_urls = Set.new
  (existing + scraped).each do |entry|
    url = entry['url']
    next unless url
    next if seen_urls.include?(url)
    seen_urls.add(url)
    merged << entry
  end
  merged
end

def build_manifest(entries)
  manifest = []
  entries.each do |entry|
    url = entry['url']
    next unless url

    result = validate_url(url)
    next unless result[:ok]

    photographer = entry['photographer'].to_s
    photographer = entry['location'].to_s if photographer.empty?
    photographer = 'Unknown' if photographer.empty?

    manifest << {
      'url' => url,
      'id' => entry['id'] || url_id(url),
      'photographer' => photographer,
      'validated_at' => Time.now.utc.iso8601,
      'etag' => result[:etag]
    }
  end
  manifest
end

$log = Logger.new STDERR

def main
  $log.info "Fetching #{CHROMECAST_HOME_URL}..."
  html = fetch_url(CHROMECAST_HOME_URL)

  state = extract_json_state(html)
  entries = parse_entries(state)
  $log.info "Found #{entries.length} unique background images from the home page."

  merged = merge_entries(load_existing_entries('chromecast.json'), entries)
  $log.info "Merged with existing chromecast.json: #{merged.length} unique URLs."

  manifest = build_manifest(merged)
  unless merged.length == manifest.length
    $log.info "#{merged.length - manifest.length} URL(s) failed validation."
  end

  File.write('chromecast.json', JSON.pretty_generate(manifest), encoding: 'UTF-8')
  $log.info "Saved #{manifest.length} validated URLs to chromecast.json"
end

main if __FILE__ == $PROGRAM_NAME
