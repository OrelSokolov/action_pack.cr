# Multipart form-data: text parts merge into params as strings, file
# parts (Content-Disposition with a filename) as ActionController::UploadedFile
# (ActionDispatch::Http::UploadedFile semantics).

require "spec"
require "http"
require "../src/action_pack_cr"

class UploadsController < ActionController::Base
  def show
  end
end

private def multipart_context(body : String, boundary : String) : HTTP::Server::Context
  headers = HTTP::Headers{"Content-Type" => "multipart/form-data; boundary=#{boundary}"}
  request = HTTP::Request.new("POST", "/uploads", headers, body)
  io = IO::Memory.new
  response = HTTP::Server::Response.new(io)
  HTTP::Server::Context.new(request, response)
end

describe "multipart file params" do
  it "exposes file parts as UploadedFile and text parts as strings" do
    boundary = "----X"
    body = "--#{boundary}\r\n" \
           "Content-Disposition: form-data; name=\"message[body]\"\r\n\r\n" \
           "Hello!\r\n" \
           "--#{boundary}\r\n" \
           "Content-Disposition: form-data; name=\"message[attachment]\"; filename=\"a.png\"\r\n" \
           "Content-Type: image/png\r\n\r\n" \
           "binary-content\r\n" \
           "--#{boundary}\r\n" \
           "Content-Disposition: form-data; name=\"message[client_message_id]\"\r\n\r\n" \
           "cmid-1\r\n" \
           "--#{boundary}--\r\n"
    context = multipart_context(body, boundary)
    controller = UploadsController.new(context)
    controller.__set_params({} of String => String)

    message = controller.params["message"].as(ActionController::Parameters)
    message["body"].should eq("Hello!")
    message["client_message_id"].should eq("cmid-1")

    file = message["attachment"].as(ActionController::UploadedFile)
    file.filename.should eq("a.png")
    file.content_type.should eq("image/png")
    file.body.should eq("binary-content")
    file.size.should eq(14)
  end

  it "passes UploadedFile through permit like a scalar" do
    boundary = "----Y"
    body = "--#{boundary}\r\n" \
           "Content-Disposition: form-data; name=\"message[attachment]\"; filename=\"b.txt\"\r\n\r\n" \
           "xyz\r\n" \
           "--#{boundary}--\r\n"
    context = multipart_context(body, boundary)
    controller = UploadsController.new(context)
    controller.__set_params({} of String => String)

    permitted = controller.params
      .require(:message)
      .permit("body", "attachment", "client_message_id")
    file = permitted["attachment"].as(ActionController::UploadedFile)
    file.filename.should eq("b.txt")
  end
end
