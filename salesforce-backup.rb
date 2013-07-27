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
  def server_url
    @server_url
  end

  def set_server_url=(new_server_url)
    @server_url = new_server_url
  end

  def session_id
    @session_id
  end

  def set_session_id=(new_session_id)
    @session_id = new_session_id
  end

  def org_id
    @org_id
  end

  def set_org_id=(new_org_id)
    @org_id = new_org_id
  end
end

class Error 
  def internal_server_error
    @internal_server_error
  end

  def set_internal_server_error=(server_error)
    @internal_server_error = server_error
  end

  def data
    @data
  end

  def set_data=(data)
    @data = data
  end
end

def login
  http = Net::HTTP.new('login.salesforce.com', 443);
  http.use_ssl = true
  path = '/services/Soap/u/28.0'

  data = <<-EOF
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

  headers = {
    'Content-Type' => 'text/xml; charset=UTF-8',
    'SOAPAction' => 'login'
  }

  resp, data = http.post(path, data, headers)

  if resp.code == '200'
    xmldoc = Document.new(data)
    server_url= XPath.first(xmldoc, '//result/serverUrl/text()')
    session_id = XPath.first(xmldoc, '//result/sessionId/text()')
    org_id = XPath.first(xmldoc, '//result/userInfo/organizationId/text()')
    
    result = Result.new
    result.set_server_url = server_url;
    result.set_session_id = session_id;
    result.set_org_id = org_id;

    return result
  else 
     error = Error.new
     error.set_internal_server_error = resp
     error.set_data = data
    
     return error
  end 
end

def error(error)
  puts error.data
end

def download_index(login) 
  http = Net::HTTP.new(SALES_FORCE_SITE, 443);

  http.use_ssl = true
  path = '/servlet/servlet.OrgExport'
  cookie = "oid=\"@oid\"; sid=\"@sid\""
  cookie = cookie.sub(/@oid/, login.org_id.value)
  cookie = cookie.sub(/@sid/, login.session_id.value)

  headers = {
    'Cookie' => cookie, 
    'X-SFDC-Session' => login.session_id.value
  }

  resp, data = http.post(path, nil, headers);

  return data.to_s.strip
end

def make_file_name() 
  date = Date::today
  
  name = "salesforce-" + date.year.to_s + "-"

  if date.month < 9
    name = name + "0" + date.month.to_s
  else
    name = name + date.month.to_s
  end

  name = name + "-" + date.day.to_s + ".ZIP"

  return name
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
  http = Net::HTTP.new(SALES_FORCE_SITE, 443);
  http.use_ssl = true
  path = url
  cookie = "oid=\"@oid\"; sid=\"@sid\""
  cookie = cookie.sub(/@oid/, login.org_id.value)
  cookie = cookie.sub(/@sid/, login.session_id.value)

  headers = {
    'Cookie' => cookie, 
    'X-SFDC-Session' => login.session_id.value
  }

  resp, data = http.head(path, headers);
  
  return resp['Content-Length'].to_i
end

def download_file(login, url, expected_size)
  http = Net::HTTP.new(SALES_FORCE_SITE, 443)
  http.use_ssl = true
  path = url

  cookie = "oid=\"@oid\"; sid=\"@sid\""
  cookie = cookie.sub(/@oid/, login.org_id.value)
  cookie = cookie.sub(/@sid/, login.session_id.value)

  headers = {
    'Cookie' => cookie, 
    'X-SFDC-Session' => login.session_id.value
  }
  
  file_name = make_file_name;
  f = open("#{DATA_DIRECTORY}/#{file_name}", "w")
  size = 0;

  begin
    http.request_get(path, headers) do |resp|      
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
result = login

if result.is_a?Error
  error(result)
else
  url = download_index(result)  
  expected_size = get_download_size(result, url)
  download_file(result, url, expected_size)
end
end

