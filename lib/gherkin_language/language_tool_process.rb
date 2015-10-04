# encoding: utf-8
require 'gherkin/formatter/json_formatter'
require 'gherkin/parser/parser'
require 'rexml/document'
require 'stringio'
require 'multi_json'
require 'term/ansicolor'
include Term::ANSIColor
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'set'
require 'digest'

# This service class provides access to language tool process.
class LanguageToolProcess
  attr_accessor :errors, :unknown_words

  VERSION = 'LanguageTool-3.0'
  URL = "https://www.languagetool.org/download/#{VERSION}.zip"

  def initialize
    path = Dir.tmpdir
    download path unless File.exist? "#{path}/#{VERSION}/languagetool-commandline.jar"
    @path = path
    @p = nil
    @reference_line = 0
    @errors = []
    @unknown_words = []
    use_user_glossary "#{path}/#{VERSION}" if File.exist? '.glossary'
  end

  def use_user_glossary(path)
    resource_path = "#{path}/org/languagetool/resource/en"
    system "cp #{resource_path}/added.txt #{resource_path}/added.copy && cp .glossary #{resource_path}/added.txt"
    at_exit do
      system "cp #{resource_path}/added.copy #{resource_path}/added.txt"
    end
  end

  def download(path)
    system "wget --quiet #{URL} -O /var/tmp/languagetool.zip"
    FileUtils.mkdir_p path
    system "unzip -qq -u /var/tmp/languagetool.zip -d #{path}"
  end

  def start!
    @errors = []
    @unknown_words = []
    @reference_line = 0
    Dir.chdir("#{@path}/#{VERSION}/") do
      @p = IO.popen('java -jar languagetool-commandline.jar --list-unknown --api --language en-US -', 'r+')
    end
  end

  def tag(sentences)
    output = ''
    Dir.chdir("#{@path}/#{VERSION}/") do
      p = IO.popen('java -jar languagetool-commandline.jar --taggeronly --api --language en-US -', 'r+')
      sentences.each { |sentence| p.write sentence }
      p.close_write
      line = p.readline
      loop do
        break if line == "<!--\n"
        output << line
        line = p.readline
      end
      p.close
    end
    output.gsub!(' ', "\n")
    output.gsub!(']', "]\n")
    output.gsub!("\n\n", "\n")
    output
  end

  def check_paragraph(paragraph)
    start_line = @reference_line
    send paragraph
    end_line = @reference_line
    send "\n\n"
    Range.new(start_line, end_line)
  end

  def send(sentence)
    @reference_line += sentence.count "\n"
    @p.write sentence
  end

  def parse_errors(result)
    doc = REXML::Document.new result
    errors = []
    doc.elements.each '//error' do |error|
      errors.push decode_error error
    end
    errors
  end

  def decode_error(error)
    Error.new(
      error.attributes['category'],
      error.attributes['context'].strip,
      error.attributes['locqualityissuetype'],
      error.attributes['msg'],
      error.attributes['replacements'],
      error.attributes['ruleId'],
      error.attributes['fromy'].to_i,
      error.attributes['toy'].to_i)
  end

  def parse_unknown_words(result)
    doc = REXML::Document.new result
    errors = []
    doc.elements.each '//unknown_words/word' do |error|
      errors.push error.text
    end
    errors
  end

  def stop!
    @p.close_write
    errors = ''
    line = @p.readline
    loop do
      break if line == "<!--\n"
      errors << line
      line = @p.readline
    end
    @errors = parse_errors errors
    @unknown_words = parse_unknown_words errors
    @p.close
  end
end