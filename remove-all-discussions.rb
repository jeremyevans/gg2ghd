require "graphql/client"
require "graphql/client/http"

OWNER, REPO, TOKEN, *extra = ARGV

if !TOKEN || !extra.empty?
  $stderr.puts(<<USAGE)
Usage: ruby remove-all-discussions.rb owner repo token"
owner: GitHub account name
 repo: GitHub repository name
token: GitHub access token (see https://docs.github.com/en/github/authenticating-to-github/creating-a-personal-access-token)
USAGE
  exit 1
end

http = GraphQL::Client::HTTP.new("https://api.github.com/graphql") do
  def headers(context)
    {
      "Authorization" => "bearer #{TOKEN}",
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

Discussions = Client.parse <<-GRAPHQL
  query {
    repository(owner: "#{OWNER}", name: "#{REPO}") {
      discussions(first: 100) {
        nodes {
          id
        }
      }
    }
  }
GRAPHQL

DeleteDiscussion = Client.parse <<-GRAPHQL
  mutation($id: ID!) {
    deleteDiscussion(input: {id: $id}) {

      discussion {
        id
      }
    }
  }
GRAPHQL

until (discussion_ids = Client.query(Discussions).to_h.dig("data", "repository", "discussions", "nodes").map{|n| n['id']}).empty?
  print "Deleting #{discussion_ids.length} discussions"
  discussion_ids.each do |id|
    Client.query(DeleteDiscussion, variables: {id: id})
    print '.'
  end
  puts
end
