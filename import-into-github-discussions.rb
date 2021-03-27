require "graphql/client"
require "graphql/client/http"
require "mail"

OWNER, REPO, TOKEN, PATH, GROUP, *extra = ARGV

if !GROUP || !extra.empty?
  $stderr.puts(<<USAGE)
Usage: ruby import-into-github-discussions.rb owner repo token path group"
owner: GitHub account name
 repo: GitHub repository name
token: GitHub access token (see https://docs.github.com/en/github/authenticating-to-github/creating-a-personal-access-token)
 path: Local path to mbox dir created using https://github.com/icy/google-group-crawler
group: Name of Google Group, used for constructing URL
USAGE
  exit 1
end

BASE_URL = "https://groups.google.com/g/#{GROUP}/c/".freeze

http = GraphQL::Client::HTTP.new("https://api.github.com/graphql") do
  def headers(context)
    {
      "Authorization" => "bearer #{ENV['GITHUB_TOKEN']}",
      "GraphQL-Features" => " discussions_api",
    }
  end
end  

schema_file = 'graphql-schema.json'
unless File.file?(schema_file)
  GraphQL::Client.dump_schema(http, schema_file)
end
schema = GraphQL::Client.load_schema(schema_file)

Client = GraphQL::Client.new(schema: schema, execute: http)

DiscussionCategories = Client.parse <<-GRAPHQL
  query {
    repository(owner: "#{OWNER}", name: "#{REPO}") {
      id
      name

      discussionCategories(first: 10) {
        nodes {
          id
          name
        }
      }
    }
  }
GRAPHQL

h = Client.query(DiscussionCategories).to_h
repo_id = h.dig("data", "repository", "id")
category_id = h.dig("data", "repository", "discussionCategories", "nodes").find{|n| n['name'] == 'General'}['id']

CreateDiscussion = Client.parse <<-GRAPHQL
  mutation($body: String!, $title: String!) {
    createDiscussion(input: {repositoryId: "#{repo_id}", categoryId: "#{category_id}", body: $body, title: $title}) {

      discussion {
        id
      }
    }
  }
GRAPHQL

AddDiscussionComment = Client.parse <<-GRAPHQL
  mutation($body: String!, $discussion_id: ID!) {
    addDiscussionComment(input: {discussionId: $discussion_id, body: $body}) {

      comment {
        id
      }
    }
  }
GRAPHQL

threads = {}

Dir.chdir(PATH) do
  Dir['m.*'].each do |filename|
    m = Mail.read(filename)
    next unless m.subject && m.date

    md = /\Am\.([^.]+)\.[^.]+\z/.match(filename) 
    thread = md[1]
    (threads[thread] ||= []) << m
  end
end

threads.each_value do |posts|
  posts.sort_by!(&:date)
end

threads = threads.to_a
threads.sort_by! do |_, posts|
  posts[0].date
end

threads.each do |thread_id, posts|
  first_post, *posts = posts

  title = first_post.subject
  body = first_post.text_part.decoded rescue (first_post.decoded)
  body = <<BODY
Google Group Post: #{BASE_URL}#{thread_id}
Google Group Date: #{first_post.date.rfc2822}
Google Group Sender: #{first_post.from.join('; ')}

#{body}
BODY

  print "Discussion: #{title}"
  h = Client.query(CreateDiscussion, variables: {title: title, body: body}).to_h
  discussion_id = h.dig('data', 'createDiscussion', 'discussion', 'id')
  print '! Comments: '

  posts.each do |post|
    body = post.text_part.decoded rescue (post.decoded)
    body = <<BODY
Google Group Date: #{post.date.rfc2822}
Google Group Sender: #{post.from.join('; ')}

#{body}
BODY

    Client.query(AddDiscussionComment, variables: {discussion_id: discussion_id, body: body})
    print '.'
  end

  puts
end
