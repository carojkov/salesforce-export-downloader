#!/usr/bin/ruby

require 'net/http'
require 'net/https'
require 'rexml/document'
require 'date'
require 'net/smtp'

include REXML

SALES_FORCE_USER_NAME="foo@myorg.com"
SALES_FORCE_PASSWD_AND_SEC_TOKEN="s3cr3txxxxxx" # your salesforce password and security token

SALES_FORCE_SITE = "?.salesforce.com" # replace ? with your instancename
DATA_DIRECTORY = "/archive/salesforce"
EMAIL_ADDRESS_FROM = "admin@myorg.com"
EMAIL_ADDRESS_TO = "admin@myorg.com"
SMTP_HOST = "localhost"

class Result
  def initialize(xmldoc)
    @xmldoc = xmldoc
  end

  def server_url
    @server_url ||= XPath.first(xmldoc, '//result/serverUrl/text()')
  end

  def session_id
    @session_id ||= XPath.first(xmldoc, '//result/sessionId/text()')
  end

  def org_id
    @org_id ||= XPath.first(xmldoc, '//result/userInfo/organizationId/text()')
  end
end


class SfError
  attr_accessor :internal_server_error, :data

  def initialize(args)
    args.each {|k,v| instance_variable_set("@#{k}",v)}
  end

  def inspect
    puts data
  end
  alias_method :to_s, :inspect
end


def login
  path = '/services/Soap/u/28.0'

  inital_data = <<-EOF
<?xml version="1.0" encoding="utf-8" ?>
<env:Envelope xmlns:xsd="http://www.w3.org/2001/XMLSchema"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
  <env:Body>
    <n1:login xmlns:n1="urn:partner.soap.sforce.com">
      <n1:username>#{SALES_FORCE_USER_NAME}</n1:username>
      <n1:password>#{SALES_FORCE_PASSWD_AND_SEC_TOKEN}</n1:password>
    </n1:login>
  </env:Body>
</env:Envelope>
  EOF

  initial_headers = {
    'Content-Type' => 'text/xml; charset=UTF-8',
    'SOAPAction' => 'login'
  }

  resp = http('login.salesforce.com').post(path, inital_data, initial_headers)

  if resp.code == '200'
    xmldoc = Document.new(resp.body)
    return Result.new({:xmldoc => xmldoc})
  else
    raise SfError.new({:internal_server_error => resp, :data => data})
  end
end

def http(host=SALES_FORCE_SITE, port=443)
    h = Net::HTTP.new(host, port)
    h.use_ssl = true
    h
end

def headers(login)
  {
    'Cookie'         => "oid=#{login.org_id.value}; sid=#{login.session_id.value}",
    'X-SFDC-Session' => login.session_id.value
  }
end

def download_index(login)
  path = '/servlet/servlet.OrgExport'
  data = http.post(path, nil, headers(login))
  data.body.strip
end

def file_name
  @file_name ||= "salesforce-#{Date::today.strftime('%Y-%m-%d')}.ZIP"
end

def email_success(file_name, size)
  subject = "Salesforce backup successfully downloaded"
  data = "Salesforce backup saved into #{file_name}, size #{size}"
  email(subject, data)
end

def email_failure(url, expected_size, code)
  subject = "Salesforce backup download failed"
  data = "Failed to download #{url} of size #{expected_size} due to #{code}"
  email(subject, data)
end

def email(subject, data)
message = <<END
From: Admin <#{EMAIL_ADDRESS_FROM}>
To: Admin <#{EMAIL_ADDRESS_TO}>
Subject: #{subject}

#{data}
END

  Net::SMTP.start(SMTP_HOST) do |smtp|
    smtp.send_message message, EMAIL_ADDRESS_TO,
                               EMAIL_ADDRESS_FROM
  end
end

def get_download_size(login, url)
  data = http.head(url, headers(login))
  data['Content-Length'].to_i
end

def download_file(login, url, expected_size)
  f = open("#{DATA_DIRECTORY}/#{file_name}", "w")
  size = 0
  begin
    http.request_get(url, headers(login)) do |resp|
      resp.read_body do |segment|
        f.write(segment)
        size = size + segment.size
      end
    end
  ensure
    f.close()
  end

  if size == expected_size
    email_success("#{DATA_DIRECTORY}/#{file_name}", size)
  else
    email_failure(url, expected_size, resp.code)
  end
end


begin
  begin
    result = login
    url = download_index(result)
    expected_size = get_download_size(result, url)
    download_file(result, url, expected_size)
  rescue Exception => e
    puts e
  end
end
