require 'rss'
require 'open-uri'
require 'addressable/uri'

class FeedsController < ApplicationController
  def index
    # x.scan(/xmlUrl=".*?"/).each {|x| puts x[7..-1] + ','}
    group = params[:group] || 'dev'

    if group == 'all'
      feeds = Rails.configuration.feeds.inject([]) do |array, e|
        array + e.second
      end
    else
      feeds = Rails.configuration.feeds[group]
    end

    @rss = RSS::Maker.make('atom') do |maker|
      maker.channel.author = 'Benjamin'.freeze
      maker.channel.about = '한국의 좋은 블로그 글들을 매일 배달해줍니다.'.freeze
      maker.channel.title = channel_title(group)

      Parallel.each(feeds, in_threads: 30) do |feed_h|
        begin
          feed_url = feed_h[:feed_url]
          feed = Rails.cache.fetch(feed_url, expires_in: cache_expiring_time) do
            puts "cache missed: #{feed_url}"
            Timeout::timeout(3) {
              Feedjira::Feed.fetch_and_parse(feed_url)
            }
          end

          next if feed.nil?
          # puts "FEED: #{feed.inspect}"

          feed.entries.each do |entry|
            if entry.published < Time.now - 15.days
              next
            end
            maker.items.new_item do |item|
              item.link = entry.url || entry.entry_id
              item.title = entry.title
              item.updated = entry.published.localtime > Time.now ? Time.now : entry.published.localtime
              item.summary = entry.content || entry.summary
              item.summary = replace_relative_image_url(item.summary, item.link)
              # Rails.logger.debug("SUMMARY: #{item.summary.inspect}")
              item.author = entry.author || feed_h[:author_name] || feed.title
              if item.link.blank?
                Rails.logger.error("ERROR - url shouldn't be null: #{entry.inspect}")
              end
            end
          end
        rescue => e
          puts "ERROR: #{e.inspect}"
          puts "ERROR: URL => #{feed_url}"
          next
        end
      end
      maker.channel.updated = maker.items.max_by { |x| x.updated.to_i }&.updated&.localtime || Time.now
    end

    group = params[:group] || 'none'
    report_google_analytics(group, group, request.user_agent)

    # binding.pry
    respond_to do |format|
      format.xml { render xml: @rss.to_xml }
      format.json
    end
  end

  def report_google_analytics(cid, title, ua)
    RestClient.post('http://www.google-analytics.com/collect',
      {
        v: '1',
        tid: 'UA-90528160-1',
        cid: SecureRandom.uuid,
        t: 'pageview',
        dh: 'awesome-blogs.petabytes.org',
        dp: cid.to_s,
        dt: title,
      },
      user_agent: ua
    )
  end

  def channel_title(category)
    case category
    when 'dev'
      'Korea Awesome Developers'.freeze
    when 'company'
      'Korea Tech Companies Blogs'.freeze
    when 'insightful'
      'Korea Insightful Blogs'.freeze
    when 'all'
      'Korea Awesome Blogs'.freeze
    else
      raise ArgumentError.new
    end
  end

  def cache_expiring_time
    if Rails.env.production?
      [10, 30, 60].sample.minutes
    else
      2.minutes
    end
  end

  def replace_relative_image_url(html_string, site_url)
    doc = Nokogiri::HTML(html_string)
    tags = {
      'img' => 'src',
      'script' => 'src',
      'a' => 'href'
    }

    base_uri = Addressable::URI.parse(site_url)
    doc.search(tags.keys.join(',')).each do |node|
      url_param = tags[node.name]

      src = node[url_param]
      unless src.blank?
        begin
          uri = Addressable::URI.parse(src)
          unless uri.host
            uri.scheme = base_uri.scheme
            uri.host = base_uri.host
            node[url_param] = uri.to_s
          end
        rescue Addressable::URI::InvalidURIError => e
          Rails.logger.error("ERROR: #{e.inspect}")
        end
      end
    end

    doc.to_html
  rescue Exception => e
    Rails.logger.error("ERROR: #{e.inspect}")
    #Rails.logger.error("HTML: #{html_string}")
    '글 읽으러 가기'
  end
end