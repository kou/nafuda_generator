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

@@configurations = {
  :debug => false,
  :rendering_mode => :big,
}
@@configurations[:debug] = true if ENV["RACK_ENV"] == "development"

def debug?
  @@configurations[:debug]
end

def rendering_mode
  @@configurations[:rendering_mode]
end

def jigoku?
  rendering_mode == :jigoku
end

def prefix
  erb(:prefix).force_encoding("ascii-8bit")
end

def description
  erb(:description).force_encoding("ascii-8bit")
end

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
    raise "invalid format: #{format.inspect}" if debug?
    not_found
  end
end

def make_context(surface, scale)
  context = Cairo::Context.new(surface)
  context.scale(scale, scale)

  context.save do
    context.set_source_color(:white)
    context.paint
  end

  context
end

def render_frame(context, paper, line_width)
  context.save do
    context.line_width = line_width
    context.rectangle(0, 0, paper.width, paper.height)
    context.stroke
  end
end

def make_layout(context, text, width, height, font)
  layout = context.create_pango_layout
  layout.text = text
  layout.width = width * Pango::SCALE
  unless @@font_families.any? {|family| family == font}
    raise "failed to find font family: #{font.inspect}" if debug?
    not_found
  end
  font_description = Pango::FontDescription.new
  font_description.family = font
  font_description.size = 12 * Pango::SCALE
  layout.font_description = font_description
  yield(layout) if block_given?
  if height
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

def load_pixbuf(info)
  screen_name = info[:screen_name]
  profile_image_url = info[:profile_image_url]
  *profile_image_url_components = profile_image_url.split(/\//)
  profile_image_last_component = profile_image_url_components.last
  profile_image_url_components[-1] =
    u(profile_image_last_component.gsub(/_normal\.([a-zA-Z]+)\z/, '.\1'))
  profile_image_url = profile_image_url_components.join("/")

  extension = $1
  image_data = cache_file("images", "#{screen_name}.#{extension}") do
    open(profile_image_url, "rb") do |image_file|
      image_file.read
    end
  end
  loader = Gdk::PixbufLoader.new
  loader.write(image_data)
  loader.close
  loader.pixbuf
end

def render_to_surface_big(surface, scale, paper, info, font)
  margin = paper.width * 0.03
  image_width = image_height = paper.width * 0.3

  context = make_context(surface, scale)
  render_frame(context, paper, margin * 0.5)

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

  pixbuf = load_pixbuf(info)
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

def prepare_jigoku_description(description)
  description = description.strip
  description.gsub(/(.)(\s+)(.)/) do |chunk|
    previous_char = $1
    spaces = $2
    next_char = $3
    if /\A[a-z\d]\z/i =~ previous_char and /\A[a-z\d]\z/i =~ next_char
      chunk
    else
      if spaces.size == 1
        new_lines = "\n"
      else
        new_lines = "\n\n"
      end
      "#{previous_char}#{new_lines}#{next_char}"
    end
  end
end

def render_witticism(context, position, witticism, paper, margin, font)
  layout = make_layout(context,
                       witticism,
                       paper.height - margin * 2,
                       nil,
                       font) do |_layout|
    _layout.context.base_gravity = :east
    description = _layout.font_description
    description.size = 16 * Pango::SCALE
    _layout.font_description = description
  end

  case position
  when :right
    witticism_x = paper.width - margin * 2
  when :left
    witticism_x = margin * 2 + layout.pixel_size[1]
  end
  witticism_y = margin
  context.save do
    context.move_to(witticism_x, witticism_y)
    context.rotate(Math::PI / 2)
    context.line_width = 10
    context.line_join = :bevel
    context.set_source_color(:white)
    context.pango_layout_path(layout)
    context.stroke
  end
  context.save do
    context.move_to(witticism_x, witticism_y)
    context.rotate(Math::PI / 2)
    context.show_pango_layout(layout)
  end
end

def render_to_surface_jigoku(surface, scale, paper, info, font)
  if paper.width > paper.height
    margin = paper.height * 0.03
  else
    margin = paper.width * 0.03
  end

  context = make_context(surface, scale)

  pixbuf = load_pixbuf(info)
  if pixbuf
    context.save do
      x_ratio = (paper.width - 10) / pixbuf.width.to_f
      y_ratio = (paper.height - 10) / pixbuf.height.to_f
      x_ratio = paper.width / pixbuf.width.to_f
      y_ratio = paper.height / pixbuf.height.to_f
      if x_ratio > y_ratio
        x_ratio = y_ratio
        translate_x = (paper.width - pixbuf.width * x_ratio) / 2.0
        translate_y = 0
      else
        y_ratio = x_ratio
        translate_x = 0
        translate_y = (paper.height - pixbuf.height * y_ratio) / 2.0
      end
      context.translate(translate_x, translate_y)
      context.scale(x_ratio, y_ratio)
      context.set_source_pixbuf(pixbuf, 0, 0)
      context.paint
    end
  end

  render_frame(context, paper, margin * 0.5)

  description = prepare_jigoku_description(info[:description])
  right_witticism, left_witticism, garbages = description.split(/\n\n/, 3)
  render_witticism(context, :right, right_witticism, paper, margin, font)
  if left_witticism
    render_witticism(context, :left, left_witticism, paper, margin, font)
  end

  screen_name = info[:screen_name]
  layout = make_layout(context,
                       "@#{screen_name}",
                       paper.width - margin * 2,
                       paper.height * 0.1,
                       font) do |_layout|
    _layout.alignment = :center
  end
  screen_name_x = margin
  screen_name_y = paper.height - layout.pixel_size[1] - margin
  context.save do
    context.move_to(screen_name_x, screen_name_y)
    context.line_width = 5
    context.line_join = :bevel
    context.set_source_color(:white)
    context.pango_layout_path(layout)
    context.stroke
  end
  context.save do
    context.move_to(screen_name_x, screen_name_y)
    context.show_pango_layout(layout)
  end

  context.show_page
end

def render_to_surface(surface, scale, paper, info, font)
  send("render_to_surface_#{rendering_mode}",
       surface, scale, paper, info, font)
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
  info[:description] = doc.elements["/user/description"].text
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
  return if debug?
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
    unless name.valid_encoding?
      raise "invalid encoding name: #{name.inspect}" if debug?
      not_found
    end
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
    raise if debug?
    not_found
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
    raise if debug?
    not_found
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
    raise if debug?
    not_found
  end
end
