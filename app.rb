# -*- coding: utf-8 -*-

require 'rubygems'
require 'sinatra'
require 'gdk_pixbuf2'
require 'pango'
require 'cairo'
require 'stringio'
require 'rexml/document'
require 'open-uri'
require 'fileutils'

include ERB::Util

get '/' do
  erb :index
end

def make_surface(paper, format, output, &block)
  case format
  when "ps", "pdf", "svg"
    Cairo.const_get("#{format.upcase}Surface").new(output, paper, &block)
  when "png"
    Cairo::ImageSurface.new(*paper.size) do |surface|
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
  unless layout.context.families.any? {|family| family.name == font}
    raise Sinatra::NotFound
  end
  font_description = Pango::FontDescription.new
  font_description.family = font
  font_description.size = 6 * Pango::SCALE
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

def render_to_surface(surface, paper, info, font)
  margin = paper.width * 0.03
  image_width = image_height = paper.width * 0.3

  context = Cairo::Context.new(surface)
  context.set_source_color(:white)
  context.paint

  context.set_source_color(:black)

  name = info[:user_real_name].gsub(/\s+/, "\n")
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

  layout = make_layout(context,
                       "@#{info[:screen_name]}",
                       paper.width - image_width - margin * 3,
                       image_height,
                       font)
  context.move_to(margin, paper.height - layout.pixel_size[1] - margin)
  context.show_pango_layout(layout)

  profile_image_url = info[:profile_image_url].gsub(/_normal\.png\z/, '.png')
  pixbuf = open(profile_image_url) do |image_file|
    loader = Gdk::PixbufLoader.new
    loader.last_write(image_file.read)
    loader.pixbuf
  end
  context.save do
    context.translate(paper.width - image_width - margin,
                      paper.height - image_height - margin)
    context.scale(image_width / pixbuf.width, image_height / pixbuf.height)
    context.set_source_pixbuf(pixbuf, 0, 0)
    context.paint
  end

  context.show_page
end

@@user_info_cache = {
  "kdmsnr" => {
    :screen_name => "kdmsnr",
    :user_real_name => "角公則",
    :profile_image_url => "/home/kou/work/rd/RubyKaigi2010/ruby.png",
  },
}
def user_info(user_name)
  @@user_info_cache[user_name] || retrieve_user_info(user_name)
end

def retrieve_user_info(user_name)
  info = {}
  open("http://twitter.com/users/#{u(user_name)}.xml") do |xml|
    doc = REXML::Document.new(xml)
    info[:screen_name] = doc.elements["/user/screen_name"].text
    info[:user_real_name] = doc.elements["/user/name"].text
    info[:profile_image_url] = doc.elements["/user/profile_image_url"].text
  end
  info
end

def render_nameplate(user, font, format, scale=1.0)
  width = 89
  height = 98
  paper = Cairo::Paper.new(width * scale, height * scale, "mm", "RubyKaigi")
  paper.unit = "pt"
  output = StringIO.new

  make_surface(paper, format, output) do |surface|
    render_to_surface(surface, paper, user_info(user), font)
  end

  content_type format
  output.string
end

def danger_path_component?(component)
  component == ".." or /\// =~ component
end

def cache_file(data, *path)
  return if path.any? {|component| danger_path_component?(component)}
  base_dir = File.expand_path(File.dirname(__FILE__))
  path = File.join(base_dir, "public", *path)
  FileUtils.mkdir_p(File.dirname(path))
  File.open(path, "w") do |file|
    file.print(data)
  end
end

get "/fonts/:font/thumbnails/:user.png" do
  begin
    user = File.basename(params[:user])
    font = params[:font]
    format = "png"

    nameplate = render_nameplate(user, font, format, 0.3)
    cache_file(nameplate, "fonts", font, "thumbnail", "#{user}.#{format}")
    nameplate
  rescue
    raise Sinatra::NotFound
  end
end

get "/fonts/:font/:user" do
  begin
    user = File.basename(params[:user], ".*")
    if /\.([a-z]+)\z/ =~ params[:user]
      format = $1
    else
      format = "png"
    end
    font = params[:font]

    nameplate = render_nameplate(user, font, format)
    cache_file(nameplate, "fonts", font, "#{user}.#{format}")
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
      @user = user
      context = Cairo::Context.new(Cairo::ImageSurface.new(1, 1))
      @families = context.create_pango_layout.context.families.collect do |family|
        name = family.name
        name.force_encoding("UTF-8") if name.respond_to?(:force_encoding)
        name
      end.sort_by {rand}[0..50].sort
      return erb :user
    end

    nameplate = render_nameplate(user, "Sans", format)
    cache_file(nameplate, "#{user}.#{format}")
    nameplate
  rescue
    raise Sinatra::NotFound
  end
end
