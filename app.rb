# -*- coding: utf-8 -*-

ENV["LANG"] = "ja_JP.UTF-8"

require 'rubygems'
require 'sinatra'
begin
  require 'gtk2'
rescue Gtk::InitError
end
require 'cairo'
require 'stringio'
require 'rexml/document'
require 'open-uri'
require 'fileutils'

include ERB::Util

get '/' do
  erb :index
end

post '/' do
  redirect "/#{params[:user]}"
end

@@font_families = Pango::CairoFontMap.default.families.collect do |family|
  name = family.name
  name.force_encoding("UTF-8") if name.respond_to?(:force_encoding)
  name
end
@@user_info_cache = {}

def make_surface(paper, scale, format, output, &block)
  width = paper.width * scale
  height = paper.height * scale
  case format
  when "ps", "pdf", "svg"
    Cairo.const_get("#{format.upcase}Surface").new(output, width, height, &block)
  when "png"
    Cairo::ImageSurface.new(width, height) do |surface|
      yield(surface)
      surface.write_to_png(output)
    end
  else
    raise Sinatra::NotFound
  end
end

def make_layout(context, text, width, height, font)
  layout = context.create_pango_layout
  layout.text = text
  layout.width = width * Pango::SCALE
  unless @@font_families.any? {|family| family == font}
    raise Sinatra::NotFound
  end
  font_description = Pango::FontDescription.new
  font_description.family = font
  font_description.size = 12 * Pango::SCALE
  layout.font_description = font_description
  yield(layout) if block_given?
  prev_size = font_description.size
  loop do
    current_width, current_height = layout.pixel_size
    if width < current_width or height < current_height
      font_description.size = prev_size
      layout.font_description = font_description
      break
    end
    prev_size = font_description.size
    font_description.size *= 1.05
    layout.font_description = font_description
  end
  context.update_pango_layout(layout)
  layout
end

def prepare_real_name(name)
  name = name.strip
  case name
  when /\(/
    name.gsub(/\s*\(/, "\n(")
  when /\//
    name.gsub(/\s*\/+\s*/, "\n")
  else
    name.gsub(/\s+/, "\n")
  end
end

def render_to_surface(surface, scale, paper, info, font)
  margin = paper.width * 0.03
  image_width = image_height = paper.width * 0.3

  context = Cairo::Context.new(surface)
  context.scale(scale, scale)

  context.set_source_color(:white)
  context.paint

  context.set_source_color(:black)

  context.save do
    context.line_width = margin * 0.5
    context.rectangle(0, 0, paper.width, paper.height)
    context.stroke
  end

  name = prepare_real_name(info[:user_real_name])
  max_name_height = paper.height - image_height - margin * 3
  layout = make_layout(context,
                       name,
                       paper.width - margin * 2,
                       max_name_height,
                       font) do |_layout|
    _layout.alignment = Pango::Layout::ALIGN_CENTER
    _layout.justify = true
  end
  context.move_to(margin, margin + (max_name_height - layout.pixel_size[1]) / 2)
  context.show_pango_layout(layout)

  screen_name = info[:screen_name]
  layout = make_layout(context,
                       "@#{screen_name}",
                       paper.width - image_width - margin * 3,
                       image_height,
                       font)
  context.move_to(margin, paper.height - layout.pixel_size[1] - margin)
  context.show_pango_layout(layout)

  profile_image_url = info[:profile_image_url].gsub(/_normal\.([a-zA-Z]+)\z/,
                                                    '.\1')
  extension = $1
  image_data = cache_file("images", "#{screen_name}.#{extension}") do
    open(profile_image_url, "rb") do |image_file|
      image_file.read
    end
  end
  loader = Gdk::PixbufLoader.new
  loader.write(image_data)
  loader.close
  pixbuf = loader.pixbuf
  if pixbuf
    context.save do
      context.translate(paper.width - image_width - margin,
                        paper.height - image_height - margin)
      context.scale(image_width / pixbuf.width, image_height / pixbuf.height)
      context.set_source_pixbuf(pixbuf, 0, 0)
      context.paint
    end
  end

  context.show_page
end

def user_info(user_name)
  @@user_info_cache[user_name] || retrieve_user_info(user_name)
end

def retrieve_user_info(user_name)
  xml_data = cache_file("users", "#{user_name}.xml") do
    open("http://twitter.com/users/#{u(user_name)}.xml") do |xml|
      xml.read
    end
  end
  info = {}
  doc = REXML::Document.new(xml_data)
  info[:screen_name] = doc.elements["/user/screen_name"].text
  info[:user_real_name] = doc.elements["/user/name"].text
  info[:profile_image_url] = doc.elements["/user/profile_image_url"].text
  info
end

def render_nameplate(user, font, format, scale=1.0)
  width = 89
  height = 98
  paper = Cairo::Paper.new(width, height, "mm", "RubyKaigi")
  paper.unit = "pt"
  output = StringIO.new

  make_surface(paper, scale, format, output) do |surface|
    render_to_surface(surface, scale, paper, user_info(user), font)
  end

  content_type format
  output.string
end

def danger_path_component?(component)
  component == ".." or /\// =~ component
end

def cache_file(*path)
  if path.any? {|component| danger_path_component?(component)}
    yield
  else
    base_dir = File.expand_path(File.dirname(__FILE__))
    cache_path = File.join(base_dir, "var", "cache", *path)
    if File.exist?(cache_path)
      File.open(cache_path, "rb") do |file|
        file.read
      end
    else
      FileUtils.mkdir_p(File.dirname(cache_path))
      data = yield
      File.open(cache_path, "wb") do |file|
        file.print(data)
      end
      data
    end
  end
end

def cache_public_file(data, *path)
  return if path.any? {|component| danger_path_component?(component)}
  base_dir = File.expand_path(File.dirname(__FILE__))
  path = File.join(base_dir, "public", *path)
  FileUtils.mkdir_p(File.dirname(path))
  File.open(path, "wb") do |file|
    file.print(data)
  end
end

def prepare_font_name(name)
  if name.respond_to?(:force_encoding)
    name.force_encoding("UTF-8")
    raise Sintara::NotFound unless name.valid_encoding?
  end
  name
end

get "/fonts/:font/thumbnails/:user.png" do
  begin
    user = File.basename(params[:user])
    font = prepare_font_name(params[:font])
    format = "png"

    nameplate = render_nameplate(user, font, format, 0.3)
    cache_public_file(nameplate,
                      "fonts", font, "thumbnails", "#{user}.#{format}")
    nameplate
  rescue
    raise Sinatra::NotFound
  end
end

get "/fonts/:font/:user" do
  begin
    user = File.basename(params[:user], ".*")
    font = prepare_font_name(params[:font])
    if /\.([a-z]+)\z/ =~ params[:user]
      format = $1
    else
      format = "png"
    end

    nameplate = render_nameplate(user, font, format)
    cache_public_file(nameplate, "fonts", font, "#{user}.#{format}")
    nameplate
  rescue
    raise Sinatra::NotFound
  end
end

get "/:user" do
  begin
    user = File.basename(params[:user], ".*")
    if /\.([a-z]+)\z/ =~ params[:user]
      format = $1
    else
      user_info(user)
      @user = user
      @families = @@font_families.sort_by {rand}[0, 50].collect do |name|
        if name.respond_to?(:force_encoding)
          name.dup.force_encoding("ASCII-8BIT")
        else
          name
        end
      end
      return erb :user
    end

    nameplate = render_nameplate(user, "Sans", format)
    cache_putblic_file(nameplate, "#{user}.#{format}")
    nameplate
  rescue
    raise Sinatra::NotFound
  end
end
