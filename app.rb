# -*- coding: utf-8 -*-

require 'rubygems'
require 'sinatra'
require 'gdk_pixbuf2'
require 'pango'
require 'cairo'
require 'stringio'
require 'rexml/document'
require 'open-uri'

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

def make_layout(context, text, width, height)
  layout = context.create_pango_layout
  layout.text = text
  layout.width = width * Pango::SCALE
  font_description = Pango::FontDescription.new("Sans 12")
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

def render_to_surface(surface, paper, info)
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
                       max_name_height) do |_layout|
    _layout.alignment = Pango::Layout::ALIGN_CENTER
    _layout.justify = true
  end
  context.move_to(margin, margin + (max_name_height - layout.pixel_size[1]) / 2)
  context.show_pango_layout(layout)

  layout = make_layout(context,
                       "@#{info[:screen_name]}",
                       paper.width - image_width - margin * 3,
                       image_height)
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

def user_info(user_name)
  info = {}
  open("http://twitter.com/users/#{u(user_name)}.xml") do |xml|
    doc = REXML::Document.new(xml)
    info[:screen_name] = doc.elements["/user/screen_name"].text
    info[:user_real_name] = doc.elements["/user/name"].text
    info[:profile_image_url] = doc.elements["/user/profile_image_url"].text
  end
  info
end

get "/:user" do
  begin
    user = File.basename(params[:user], ".*")
    if /\.([a-z]+)\z/ =~ params[:user]
      format = $1
    else
      format = "png"
    end

    width = 89
    height = 98
    paper = Cairo::Paper.new(width, height, "mm", "RubyKaigi")
    paper.unit = "pt"
    output = StringIO.new

    make_surface(paper, format, output) do |surface|
      render_to_surface(surface, paper, user_info(user))
    end

    base_dir = File.expand_path(File.dirname(__FILE__))
    File.open(File.join(base_dir, "public", "#{user}.#{format}"), "w") do |file|
      file.print(output.string)
    end
    content_type format
    output.string
  rescue
    raise Sinatra::NotFound
  end
end
