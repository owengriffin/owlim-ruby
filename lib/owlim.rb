require "rubygems"
require "uri"
require "uuid"
require "erb"
require "net/http"
require "cgi"
require "json"
require "rexml/document"

class OWLIM

  attr :prefix_hash

  def initialize(url)
    @endpoint = url
    uri = URI.parse(url)

    @host = uri.host
    @port = uri.port
    @path = uri.path

    @prefix_hash = {}

    Net::HTTP.version_1_2
  end

  def host
    return @endpoint
  end

  def list
    result = ""

    Net::HTTP.start(@host, @port) do |http|
      response = http.get("#{@path}/repositories",
                          {"Accept" => "application/sparql-results+json"})
      result = response.body
    end

    hash = JSON.parse(result)

    hash["results"]["bindings"].map {|b| b["id"]["value"]}
  end

  def create(repository, opts={})
    rdftransaction = create_repository(repository, opts)

    Net::HTTP.start(@host, @port) do |http|
      response = http.post("#{@path}/repositories/SYSTEM/statements",
                           rdftransaction,
                           {"Content-Type" => "application/x-rdftransaction"})
    end
  end

  def import(repository, data_file, opts={})
    http = Net::HTTP.new(@host, @port)
    http.read_timeout = 60 * 60
    req = Net::HTTP::Post.new("#{@path}/repositories/#{repository}/statements")
    if opts[:content_type]
      req["Content-Type"] = opts[:content_type]
    elsif opts[:format]
      if ct = content_type(opts[:format])
        req["Content-Type"] = ct
      else
        raise "ERROR: Content-Type detection failed for #{data_file}."
      end
    else
      if suffix = File.basename(data_file)[/\.(\w+)$/, 1]
        if ct = content_type(suffix.downcase)
          req["Content-Type"] = ct
        else
          raise "ERROR: Content-Type detection failed for '#{data_file}'."
        end
      else
        raise "ERROR: Invalid suffix (#{data_file}). Explicitly specify the RDF format."
      end
    end
    #req["Transfer-Encoding"] = "chunked"
    req["Content-Length"] = File.size(data_file)

    res = nil
    File.open(data_file, "r") do |f|
      req.body_stream = f
      res = http.request(req)
    end
  end

  def export(repository, opts={})
    result = ""

    if opts[:format]
      unless format = content_type(opts[:format])
        raise "ERROR: Invalid format (#{opts[:format]})."
      end
    else
      format = "application/rdf+xml"
    end

    Net::HTTP.start(@host, @port) do |http|
      path = "#{@path}/repositories/#{repository}/statements?infer=false"
      response = http.get(path, {"Accept" => format})
      result = response.body
    end

    result
  end

  def size(repository)
    result = ""

    Net::HTTP.start(@host, @port) do |http|
      response = http.get("#{@path}/repositories/#{repository}/size")
      result = response.body
    end

    result.to_i
  end

  def clear(repository)
    Net::HTTP.start(@host, @port) do |http|
      http.read_timeout = 60 * 60
      response = http.delete("#{@path}/repositories/#{repository}/statements")
    end
  end

  def drop(repository)
    clear(repository)

    rdftransaction = drop_repository(repository)

    Net::HTTP.start(@host, @port) do |http|
      response = http.post("#{@path}/repositories/SYSTEM/statements",
                           rdftransaction,
                           {"Content-Type" => "application/x-rdftransaction"})
    end
  end

  def prefix
    ary = []
    @prefix_hash.sort.each { |key, value|
      ary << "PREFIX #{key}: <#{value}>"
    }
    return ary.join("\n")
  end

  def query(repository, sparql, opts={}, &block)
    opts[:infer] = false if opts[:infer].nil?
    result = ""

    case opts[:format]
    when "xml"
      format = "application/sparql-results+xml"
    when "json"
      format = "application/sparql-results+json"
    else # tabular text
      format = "application/sparql-results+json"
    end

    sparql_str = CGI.escape(prefix + sparql)
    
    Net::HTTP.start(@host, @port) do |http|
      path = "#{@path}/repositories/#{repository}?query=#{sparql_str}&infer=#{opts[:infer]}"
      http.get(path, {"Accept" => "#{format}"}) { |body|
        if block and opts[:format] # xml or json
          yield body
        else # tabular text
          result += body
        end
      }
    end

    if opts[:format] # xml or json
      return result
    else # generate tabular text
      table = format_json(result)
      if block
        yield table
      else
        return table
      end
    end
  end

  def find(repository, keyword, opts={}, &block)
    sparql = "select ?s ?p ?o where { ?s ?t '#{keyword}'. ?s ?p ?o . }"
    query(repository, sparql, opts, &block)
  end

  def head(repository, opts={}, &block)
    limit  = opts[:limit] || 20
    offset = (opts[:offset] || 1).to_i + 61
    sparql = "select ?s ?p ?o where { ?s ?p ?o . } offset #{offset} limit #{limit}"
    query(repository, sparql, opts, &block)
  end

  def prefix_default
    @prefix_hash = {
      "rdf"       => "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
      "rdfs"      => "http://www.w3.org/2000/01/rdf-schema#",
      "owl"       => "http://www.w3.org/2002/07/owl#",
      "xsd"       => "http://www.w3.org/2001/XMLSchema#",
      "pext"      => "http://proton.semanticweb.org/protonext#",
      "psys"      => "http://proton.semanticweb.org/protonsys#",
      "xhtml"     => "http://www.w3.org/1999/xhtml#",
      "dc"        => "http://purl.org/dc/elements/1.1/",
      "dcterms"   => "http://purl.org/dc/terms/",
      "foaf"      => "http://xmlns.com/foaf/0.1/",
      "skos"      => "http://www.w3.org/2004/02/skos/core#",
      "void"      => "http://rdfs.org/ns/void#",
      "dbpedia"   => "http://dbpedia.org/resource/",
      "dbp"       => "http://dbpedia.org/property/",
      "dbo"       => "http://dbpedia.org/ontology/",
      "yago"      => "http://dbpedia.org/class/yago/",
      "fb"        => "http://rdf.freebase.com/ns/",
      "sioc"      => "http://rdfs.org/sioc/ns#",
      "geo"       => "http://www.w3.org/2003/01/geo/wgs84_pos#",
      "geonames"  => "http://www.geonames.org/ontology#",
      "bibo"      => "http://purl.org/ontology/bibo/",
      "prism"     => "http://prismstandard.org/namespaces/basic/2.1/",
    }
  end

  private

  def content_type(format)
    case format
    when "ttl", "turtle"
      ct = 'application/x-turtle'
    when "rdf", "rdfxml"
      ct = 'application/rdf+xml'
    when "n3"
      ct = 'text/rdf+n3'
    when "nt"
      ct = 'text/plain'
    when "trix"
      ct = 'application/trix'
    when "trig"
      ct = 'application/x-trig'
    when "rdfbin"
      ct = 'application/x-binary-rdf'
    else
      ct = false
    end
    return ct
  end

  def format_json(json)
    begin
      hash = JSON.parse(json)
      head = hash["head"]["vars"]
      body = hash["results"]["bindings"]
    rescue
      return ""
    end
    text = ""
    text << head.join("\t") + "\n"
    body.each do |result|
      ary = []
      head.each do |key|
        data = result[key] || { "type" => '', "value" => ''}
        if data["type"] == "uri"
          uri = '<' + data["value"].gsub('\\', '') + '>'
          ary << uri
        else
          val = data["value"].gsub('\/', '/')
          ary << val
        end
      end
      text << ary.join("\t") + "\n"
    end
    return text
  end

  def create_repository(repository, opts = {})
    uuid0 = UUID.new.generate
    uuid1 = UUID.new.generate
    uuid2 = UUID.new.generate
    uuid3 = UUID.new.generate
    repository_id = repository
    repository_label = opts[:repository_label]
    default_namespace = opts[:default_namespace]
    base_url = opts[:base_url]
    license = opts[:license]

    template = "/owlim/create_repository.xml.erb"
    erb = ERB.new(File.read(File.dirname(__FILE__) + template), nil, "-")
    erb.result(binding)
  end

  def drop_repository(repository)
    pred = "<http://www.openrdf.org/config/repository#repositoryID>"
    obj = "\"#{repository}\""

    result = ""
    Net::HTTP.start(@host, @port) do |http|
      path = "#{@path}/repositories/SYSTEM/statements?pred=#{CGI.escape(pred)}&obj=#{CGI.escape(obj)}&infer=true"
      response = http.get(path, {"Accept" => "application/trix"})
      result = response.body
    end

    doc = REXML::Document.new result
    bnode_id = doc.elements["TriX/graph/id"].text

    template = "/owlim/drop_repository.xml.erb"
    erb = ERB.new(File.read(File.dirname(__FILE__) + template), nil, "-")
    erb.result(binding)
  end

end
