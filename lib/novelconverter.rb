# -*- coding: utf-8 -*-
#
# Copyright 2013 whiteleaf. All rights reserved.
#

require "fileutils"
require "stringio"
require_relative "novelsetting"
require_relative "inspector"
require_relative "illustration"
require_relative "loadconverter"
require_relative "downloader"
require_relative "template"
require_relative "progressbar"
require_relative "helper"
require_relative "inventory"
require_relative "html"
require_relative "eventable"

class NovelConverter
  include Narou::Eventable

  NOVEL_TEXT_TEMPLATE_NAME = "novel.txt"
  NOVEL_TEXT_TEMPLATE_NAME_FOR_IBUNKO = "ibunko_novel.txt"

  attr_reader :use_dakuten_font

  if Narou.already_init?
    @@site_settings = Downloader.load_settings
  end

  #
  # 指定の小説を整形・変換する
  #
  def self.convert(target, options = {})
    options = {
      # default paraeters
      output_filename: nil, display_inspector: false,
      ignore_force: false, ignore_default: false
    }.merge(options)
    setting = NovelSetting.load(target, options[:ignore_force], options[:ignore_default])
    if setting
      novel_converter = new(setting, options[:output_filename], options[:display_inspector])
      return {
        converted_txt_path: novel_converter.convert_main,
        use_dakuten_font: novel_converter.use_dakuten_font
      }
    end
    nil
  end

  #
  # テキストファイルを整形・変換する
  #
  def self.convert_file(filename, options = {})
    options = {
      # default parameters
      encoding: nil, output_filename: nil, display_inspector: false,
      ignore_force: false, ignore_default: false
    }.merge(options)
    output_filename = options[:output_filename]
    if output_filename
      archive_path = File.dirname(output_filename) + "/"
    else
      archive_path = File.dirname(filename) + "/"
    end
    setting = NovelSetting.create(archive_path, options[:ignore_force], options[:ignore_default])
    setting.author = ""
    setting.title = File.basename(filename)
    novel_converter = new(setting, output_filename, options[:display_inspector])
    text = open(filename, "r:BOM|UTF-8") { |fp| fp.read }.gsub("\r", "")
    if options[:encoding]
      text.force_encoding(options[:encoding]).encode!(Encoding::UTF_8)
    end
    {
      converted_txt_path: novel_converter.convert_main(text),
      use_dakuten_font: novel_converter.use_dakuten_font
    }
  end

  def self.stash_aozora_fonts_directory
    fonts_path = File.join(File.dirname(Narou.get_aozoraepub3_path), "template/OPS/fonts")
    return unless File.exist?(fonts_path)
    FileUtils.mv(fonts_path, fonts_path + "_hide")
  end

  def self.visible_aozora_fonts_directory
    fonts_path = File.join(File.dirname(Narou.get_aozoraepub3_path), "template/OPS/fonts")
    return unless File.exist?(fonts_path + "_hide")
    FileUtils.mv(fonts_path + "_hide", fonts_path)
  end

  #
  # AozoraEpub3でEPUBファイル作成
  #
  # AozoraEpub3は.jarがあるところがカレントディレクトリじゃないとうまく動かない
  # MEMO:
  # 逆にカレントディレクトリにAozoraEpub3の必須ファイルを置いて手を加えることで、
  # テンプレート等の差し替えが容易になる
  #
  # 返り値：正常終了 :success、エラー終了 :error、AozoraEpub3が見つからなかった nil
  #
  def self.txt_to_epub(filename, use_dakuten_font = false, dst_dir = nil, device = nil, verbose = false)
    abs_srcpath = File.expand_path(filename)
    src_dir = File.dirname(abs_srcpath)

    cover_option = ""
    # MEMO: 外部実行からだと -c FILENAME, -c 1 オプションはぬるぽが出て動かない
    cover_filename = get_cover_filename(src_dir)
    if cover_filename
      cover_option = "-c 0"   # 先頭の挿絵を表紙として利用
    end

    dst_option = ""
    if dst_dir
      dst_option = %!-dst "#{File.expand_path(dst_dir)}"!
    end

    ext_option = ""
    device_option = ""
    if device
      case device.name
      when "Kobo"
        ext_option = "-ext " + device.ebook_file_ext
      when "Kindle"
        device_option = "-device kindle"
      end
    end

    pwd = Dir.pwd

    aozoraepub3_path = Narou.get_aozoraepub3_path
    unless aozoraepub3_path
      error "AozoraEpub3が見つからなかったのでEPUBが出力出来ませんでした。" +
            "narou initでAozoraEpub3の設定を行なって下さい"
      return nil
    end
    aozoraepub3_basename = File.basename(aozoraepub3_path)
    aozoraepub3_dir = File.dirname(aozoraepub3_path)

    java_encoding = "-Dfile.encoding=UTF-8"

    if Helper.os_cygwin?
      abs_srcpath = Helper.convert_to_windows_path(abs_srcpath)
    end
    Dir.chdir(aozoraepub3_dir)
    command = %!java #{java_encoding} -cp #{aozoraepub3_basename} AozoraEpub3 -enc UTF-8 -of #{device_option} ! +
              %!#{cover_option} #{dst_option} #{ext_option} "#{abs_srcpath}"!
    if Helper.os_windows?
      command = "cmd /c " + command.encode(Encoding::Windows_31J)
    end
    stash_aozora_fonts_directory unless use_dakuten_font
    print "AozoraEpub3でEPUBに変換しています"
    begin
      res = Helper::AsyncCommand.exec(command) do
        print "."
      end
    ensure
      visible_aozora_fonts_directory unless use_dakuten_font
      Dir.chdir(pwd)
    end

    # AozoraEpub3はエラーだとしてもexitコードは0なので、
    # 失敗した場合はjavaが実行できない場合と確定できる
    unless res[2].success?
      puts
      puts res
      error "JavaがインストールされていないかAozoraEpub3実行時にエラーが発生しました。EPUBを作成出来ませんでした"
      return :error
    end

    stdout_capture = res[0]

    # Javaの実行環境に由来するであろうエラー
    if stdout_capture =~ /Error occurred during initialization of VM/
      puts
      warn stdout_capture.strip
      warn "-" * 70
      error "Javaの実行エラーが発生しました。EPUBを作成出来ませんでした\n" \
            "Hint: 複数のJava環境が混じっていると起きやすいエラーのようです"
      return :error
    end

    error_list = stdout_capture.scan(/^(?:\[ERROR\]|エラーが発生しました :).+$/)
    warn_list = stdout_capture.scan(/^\[WARN\].+$/)
    info_list = stdout_capture.scan(/^\[INFO\].+$/)

    if verbose
      puts
      puts "==== AozoraEpub3 stdout capture " + "=" * 47
      puts stdout_capture.strip
      puts "=" * 79
    end

    if !error_list.empty? || !warn_list.empty?
      unless verbose
        puts
        puts error_list, warn_list
      end
      unless error_list.empty?
        # AozoraEpub3 のエラーにはEPUBが出力されないエラーとEPUBが出力されるエラーの2種類ある。
        # EPUBが出力される場合は「変換完了」という文字があるのでそれを検出する
        if stdout_capture !~ /^変換完了/
          error "AozoraEpub3実行中にエラーが発生したため、EPUBが出力出来ませんでした"
          return :error
        end
      end
    end
    puts "変換しました"
    :success
  end

  #
  # EPUBファイルをkindlegenでMOBIへ
  # AozoraEpub3.jar と同じ場所に kindlegen が無ければ何もしない
  #
  # 返り値：正常終了 :success、エラー終了 :error、中断終了 :abort
  #
  def self.epub_to_mobi(epub_path, verbose = false)
    kindlegen_path = File.join(File.dirname(Narou.get_aozoraepub3_path), "kindlegen")
    if Dir.glob(kindlegen_path + "*").empty?
      error "kindlegenが見つかりませんでした。AozoraEpub3と同じディレクトリにインストールして下さい"
      return :error
    end

    if Helper.os_cygwin?
      epub_path = Helper.convert_to_windows_path(epub_path)
    end
    command = %!"#{kindlegen_path}" -locale ja "#{epub_path}"!
    if Helper.os_windows?
      command.encode!(Encoding::Windows_31J)
    end
    print "kindlegen実行中"
    res = Helper::AsyncCommand.exec(command) do
      print "."
    end
    stdout_capture, _, proccess_status = res
    stdout_capture.force_encoding(Encoding::UTF_8)

    if verbose
      puts
      puts "==== kindlegen stdout capture " + "=" * 49
      puts stdout_capture.gsub("\n\n", "\n").strip
      puts "=" * 79
    end

    if proccess_status.exited?
      if proccess_status.exitstatus == 2
        puts ""
        error "kindlegen実行中にエラーが発生したため、MOBIが出力出来ませんでした"
        if stdout_capture.scan(/(エラー\(.+?\):\w+?:.+)$/)
          error $1
        end
        return :error
      end
    else
      puts ""
      error "kindlegenが中断させられたぽいのでMOBIは出力出来ませんでした"
      return :abort
    end
    puts "変換しました"
    :success
  end

  #
  # 変換された整形済みテキストファイルをデバイスに対応した書籍データに変換する
  #
  def self.convert_txt_to_ebook_file(txt_path, options)
    options = {
      use_dakuten_font: false,
      dst_dir: nil,
      device: nil,
      verbose: false,
      no_epub: false,
      no_mobi: false,
      no_strip: false,
      no_cleanup_txt: false,
    }.merge(options)

    device = options[:device]
    clean_up_file_list = []

    return false if options[:no_epub]
    clean_up_file_list << txt_path unless options[:no_cleanup_txt]
    # epub
    status = NovelConverter.txt_to_epub(txt_path, options[:use_dakuten_font],
                                        options[:dst_dir], device, options[:verbose])
    return nil if status != :success
    if device && device.kobo?
      epub_ext = device.ebook_file_ext
    else
      epub_ext = ".epub"
    end
    epub_path = txt_path.sub(/.txt$/, epub_ext)

    if !device || !device.kindle? || options[:no_mobi]
      puts File.basename(epub_path) + " を出力しました"
      puts "<bold><green>EPUBファイルを出力しました</green></bold>".termcolor
      return epub_path
    end

    clean_up_file_list << epub_path
    # mobi
    status = NovelConverter.epub_to_mobi(epub_path, options[:verbose])
    return nil if status != :success
    mobi_path = epub_path.sub(/\.epub$/, device.ebook_file_ext)

    # strip
    unless options[:no_strip]
      puts "kindlestrip実行中"
      begin
        SectionStripper.strip(mobi_path, nil, false)
      rescue StripException => e
        error "#{e.message}"
      end
    end
    puts File.basename(mobi_path).encode(Encoding::UTF_8) + " を出力しました"
    puts "<bold><green>MOBIファイルを出力しました</green></bold>".termcolor

    return mobi_path
  ensure
    if Narou.economy?("cleanup_temp")
      # 作業用ファイルを削除
      clean_up_temp_files(clean_up_file_list)
    end
  end

  def self.clean_up_temp_files(path_list)
    path_list.each do |path|
      FileUtils.rm_f(path)
    end
  end

  def initialize(setting, output_filename = nil, display_inspector = false, output_text_dir = nil)
    @setting = setting
    @novel_id = setting.id
    @novel_author = setting.author
    @novel_title = setting.title
    @output_filename = output_filename
    @inspector = Inspector.new(@setting)
    @illustration = Illustration.new(@setting, @inspector)
    @display_inspector = display_inspector
    @use_dakuten_font = false
    @converter = create_converter
    @converter.output_text_dir = output_text_dir
  end

  #
  # 変換処理メインループ
  #
  def convert_main(text = nil)
    display_header
    initialize_event

    if text
      converted_text = convert_main_for_text(text)
    else
      converted_text = convert_main_for_novel
      update_latest_convert_novel
    end

    inspect_novel(converted_text)

    output_path = create_output_path(text, converted_text)
    File.write(output_path, converted_text)

    display_footer

    output_path
  end

  def initialize_event
    progressbar = nil

    one(:"convert_main.init") do |subtitles|
      progressbar = ProgressBar.new(subtitles.size)
    end
    on(:"convert_main.loop") do |i|
      progressbar.output(i) if progressbar
    end
    one(:"convert_main.finish") do
      progressbar.clear if progressbar
    end
  end

  def display_header
    print "ID:#{@novel_id}　" if @novel_id
    puts "#{@novel_title} の変換を開始"
  end

  def display_footer
    puts "縦書用の変換が終了しました"
  end

  def load_novel_section(subtitle_info, section_save_dir)
    file_subtitle = subtitle_info["file_subtitle"] || subtitle_info["subtitle"]   # 互換性維持のため
    path = File.join(section_save_dir, "#{subtitle_info["index"]} #{file_subtitle}.yaml")
    YAML.load_file(path)
  rescue Errno::ENOENT => e
    error "#{path} を見つけることが出来ませんでした。narou update #{@novel_id} を実行することで、" \
          "削除されてしまったファイルを再ダウンロードすることが出来ます"
    exit Narou::EXIT_ERROR_CODE
  end

  # is_hotentry を有効にすると、テンプレートで作成するテキストファイルに
  # あらすじ、作品タイトル、本の読み終わり表示が付与されなくなる
  def create_novel_text_by_template(sections, toc, is_hotentry = false)
    cover_chuki = create_cover_chuki
    device = Narou.get_device
    setting = @setting
    processed_title = decorate_title(toc["title"])
    tempalte_name = (device && device.ibunko? ? NOVEL_TEXT_TEMPLATE_NAME_FOR_IBUNKO : NOVEL_TEXT_TEMPLATE_NAME)
    Template.get(tempalte_name, binding, 1.1)
  end

  def decorate_title(title)
    processed_title = title
    data = Database.instance.get_data("id", @novel_id)
    # タイトルに新着更新日を付加する
    if @setting.enable_add_date_to_title
      new_arrivals_date = data[@setting.title_date_target] || Time.now
      reverse_time = (3153600000 - new_arrivals_date.to_i).to_s
      date_str = new_arrivals_date.strftime(@setting.title_date_format).gsub("$s", reverse_time)
      if @setting.title_date_align == "left"
        processed_title = date_str + processed_title
      else  # right
        processed_title += date_str
      end
    end
    # タイトルに完結したかどうかを付加する
    if @setting.enable_add_end_to_title
      tags = data["tags"] || []
      if tags.include?("end")
        processed_title += " (完結)"
      end
    end
    # タイトルがルビ化されてしまうのを抑制
    processed_title = processed_title.gsub("《", "※［＃始め二重山括弧］")
                                     .gsub("》", "※［＃終わり二重山括弧］")
    processed_title
  end

  #
  # 表紙用の画像名取得
  #
  def self.get_cover_filename(archive_path)
    [".jpg", ".png", ".jpeg"].each do |ext|
      filename = "cover#{ext}"
      cover_path = File.join(archive_path, filename)
      if File.exist?(cover_path)
        return filename
      end
    end
    nil
  end

  #
  # 表紙用挿絵注記作成
  #
  def create_cover_chuki
    cover_filename = self.class.get_cover_filename(@setting.archive_path)
    if cover_filename
      "［＃挿絵（#{cover_filename}）入る］"
    else
      ""
    end
  end

  #
  # 目次情報からサイト設定を取得
  #
  def find_site_setting(toc_url)
    @@site_settings.find { |s| s.multi_match(toc_url, "url") }
  end

  #
  # 各小説用の converter.rb 変換オブジェクトを生成
  #
  def create_converter
    load_converter(@novel_title, @setting.archive_path).new(@setting, @inspector, @illustration)
  end

  #
  # 最終的に出力するパスを生成
  #
  def create_output_path(is_text_file_mode, converted_text)
    output_path = ""
    if @output_filename
      output_path = File.join(@setting.archive_path, File.basename(@output_filename))
    else
      if is_text_file_mode
        info = get_title_and_author_by_text(converted_text)
      else
        info = { "author" => @novel_author, "title" => @novel_title }
      end
      filename = Narou.create_novel_filename(info)
      output_path = File.join(@setting.archive_path, filename)
      if output_path !~ /\.\w+$/
        output_path += ".txt"
      end
    end
    output_path
  end

  #
  # テキストファイル変換時の実質的なメイン処理
  #
  def convert_main_for_text(text)
    result = @converter.convert(text, "textfile")
    unless @setting.enable_enchant_midashi
      @inspector.info "テキストファイルの処理を実行しましたが、改行直後の見出し付与は有効になっていません。" +
                      "setting.ini の enable_enchant_midashi を true にすることをお薦めします。"
    end
    splited = result.split("\n", 3)
    # 表紙の挿絵注記を3行目に挟み込む
    converted_text = [splited[0], splited[1], create_cover_chuki, splited[2]].join("\n")

    @use_dakuten_font = @converter.use_dakuten_font

    converted_text
  end

  #
  # 管理小説変換時の実質的なメイン処理
  #
  # 引数 subtitles にデータを渡した場合はそれを直接使う
  # is_hotentry を有効にすると出力されるテキストファイルにあらすじや作品タイトル等が含まれなくなる
  #
  def convert_main_for_novel(subtitles = nil, is_hotentry = false)
    toc = Downloader.get_toc_data(@setting.archive_path)
    unless subtitles
      subtitles = cut_subtitles(toc["subtitles"])
    end
    @converter.subtitles = subtitles
    toc["story"] = @converter.convert(toc["story"], "story")
    html = HTML.new
    html.strip_decoration_tag = @setting.enable_strip_decoration_tag
    site_setting = find_site_setting(toc["toc_url"])
    html.set_illust_setting({current_url: site_setting["illust_current_url"],
                             grep_pattern: site_setting["illust_grep_pattern"]})

    sections = subtitles_to_sections(subtitles, html)
    converted_text = create_novel_text_by_template(sections, toc, is_hotentry)

    converted_text
  end

  def cut_subtitles(subtitles)
    case cut_size = @setting.cut_old_subtitles
    when 0
      result = subtitles
    when 1...subtitles.size
      puts "#{cut_size}話分カットして変換します"
      result = subtitles[cut_size..-1]
    else
      puts "最新話のみ変換します"
      result = [subtitles[-1]]
    end
    result
  end

  #
  # subtitle info から変換処理をする
  #
  def subtitles_to_sections(subtitles, html)
    sections = []
    section_save_dir = Downloader.get_novel_section_save_dir(@setting.archive_path)

    trigger(:"convert_main.init", subtitles)

    subtitles.each_with_index do |subinfo, i|
      trigger(:"convert_main.loop", i)
      @converter.current_index = i
      section = load_novel_section(subinfo, section_save_dir)
      if section["chapter"].length > 0
        section["chapter"] = @converter.convert(section["chapter"], "chapter")
      end
      @inspector.subtitle = section["subtitle"]
      element = section["element"]
      data_type = element.delete("data_type") || "text"
      element.each do |text_type, elm_text|
        if data_type == "html"
          html.string = elm_text
          elm_text = html.to_aozora
        end
        element[text_type] = @converter.convert(elm_text, text_type)
      end
      section["subtitle"] = @converter.convert(section["subtitle"], "subtitle")
      sections << section
    end
    @use_dakuten_font = @converter.use_dakuten_font
    sections
  ensure
    trigger(:"convert_main.finish")
  end

  #
  # テキストデータ先頭二行からタイトルと作者名を取得
  #
  def get_title_and_author_by_text(text)
    title, author = text.split("\n", 3)
    { "title" => title, "author" => author }
  end

  def inspect_novel(text)
    if @setting.enable_inspect
      @inspector.inspect_end_touten_conditions(text)   # 行末読点の現在状況を調査する
      @inspector.countup_return_in_brackets(text)      # カギ括弧内の改行状況を調査する
    end

    if !@display_inspector
      unless @inspector.empty?
        puts "小説状態の調査結果を #{Inspector::INSPECT_LOG_NAME} に出力しました"
      end
    else
      # 小説の監視・検査状況を表示する
      if @inspector.error? || @inspector.warning?
        puts "<bold><yellow>―――― 小説にエラーもしくは警告が存在します ――――</yellow></bold>".termcolor
        puts ""
        @inspector.display(Inspector::ERROR | Inspector::WARNING)
        puts ""
      end
      if @inspector.info?
        puts "<bold><yellow>―――― 小説の検査状況を表示します ――――</yellow></bold>".termcolor
        puts ""
        @inspector.display(Inspector::INFO)
        puts ""
      end
    end

    @inspector.save
  end

  #
  # 最近変換した小説IDを記録更新
  #
  def update_latest_convert_novel
    id = Downloader.get_id_by_target(@novel_title)
    Inventory.load("latest_convert").tap { |inv|
      inv["id"] = id
      inv.save
    }
  end
end
