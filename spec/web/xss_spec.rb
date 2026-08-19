require_relative '../spec_helper'
require 'cgi'
require 'json'

describe Oxidized::API::WebApp do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  before do
    @nodes = mock('Oxidized::Nodes')
    app.set(:nodes, @nodes)
  end

  describe 'reflected XSS prevention' do
    # Attack scenarios basing on the node name are highly hypothetical. The node
    # name is used to look up the node in Oxidized before the view is rendered,
    # so a non-existing node raises NodeNotFound and the payload is never
    # displayed.
    # Exploiting this would require the ability to manipulate the node names in
    # Oxidized itself (i.e. control over the node source/backend). These tests
    # mock the data layer to reach the rendering path and verify escaping.
    it 'escapes node name in /node/version versions list' do
      # Use a payload without '/' so the routing does not split on rpartition('/')
      malicious = '<img src=x onerror=alert(1)>'
      @nodes.expects(:version).with(malicious, nil).returns([])

      get "/node/version?node_full=#{CGI.escape(malicious)}"

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('&lt;img src=x onerror=alert(1)&gt;')
      _(last_response.body).wont_include('<img src=x onerror=alert(1)>')
    end

    it 'escapes node name in /node/version/view' do
      malicious = '<script>alert(1)</script>'
      @nodes.expects(:get_version).with(malicious, '', 'abc123').returns('device config')

      get "/node/version/view?node=#{CGI.escape(malicious)}&group=&oid=abc123&epoch=0&num=1"

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('&lt;script&gt;alert(1)&lt;/script&gt;')
      _(last_response.body).wont_include('<script>alert(1)</script>')
    end

    it 'escapes node name in /node/version/diffs' do
      malicious = '<script>alert(1)</script>'
      versions = [{ oid: 'C006', time: Time.parse('2025-02-05 19:49:00 +0100') }]
      @nodes.expects(:version).with(malicious, nil).returns(versions)
      @nodes.expects(:get_diff).with(malicious, '', 'C006', nil).returns(
        { patch: "- old line\n+ new line\n", stat: [1, 1] }
      )

      get "/node/version/diffs?node=#{CGI.escape(malicious)}&group=&oid=C006&epoch=0&num=1"

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('&lt;script&gt;alert(1)&lt;/script&gt;')
      _(last_response.body).wont_include('<script>alert(1)</script>')
    end
  end

  describe 'stored XSS prevention' do
    # The /nodes and /nodes/stats tables are rendered client-side from an AJAX
    # (DataTables server-side processing) feed, so node names are no longer
    # interpolated into the server-rendered HTML.  The stored-XSS guarantee is
    # therefore twofold:
    #   1. the HTML shell never contains the raw payload, and it ships the
    #      oxEscHtml() helper through which every user-controlled cell is
    #      rendered client-side; and
    #   2. the JSON feed is served as application/json (inert – a browser never
    #      parses it as HTML) with the payload preserved as a plain string
    #      value rather than as markup.
    before do
      @nodes.stubs(:to_a).returns([])
      app.set(:node_list_cache, Oxidized::API::NodeListCache.new(@nodes))
      app.set(:error_cache, Oxidized::API::ErrorCache.new(@nodes))
      app.set(:stats_cache, Oxidized::API::StatsCache.new(@nodes))
    end

    it 'does not interpolate node names into the /nodes HTML shell' do
      get '/nodes'

      _(last_response.ok?).must_equal true
      _(last_response.body).wont_include("'><script>alert(1)</script>")
      _(last_response.body).wont_include('<script>alert(1)</script>')
      # every user-controlled cell is rendered through this escaper
      _(last_response.body).must_include('function oxEscHtml')
    end

    it 'serves node names as inert JSON data on /nodes/datatables' do
      malicious = "'><script>alert(1)</script>"
      @nodes.stubs(:list).returns(
        [{ name: malicious, ip: '10.0.0.1', model: 'ios',
           full_name: malicious, group: 'default', last: nil }]
      )

      get '/nodes/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      _(last_response.ok?).must_equal true
      _(last_response.content_type).must_include('application/json')
      result = JSON.parse(last_response.body)
      # the payload round-trips as a plain string value, not as markup
      _(result['data'].first['name']).must_equal malicious
    end

    it 'does not interpolate node names into the /nodes/stats HTML shell' do
      get '/nodes/stats'

      _(last_response.ok?).must_equal true
      _(last_response.body).wont_include("'><script>alert(1)</script>")
      _(last_response.body).wont_include('<script>alert(1)</script>')
      _(last_response.body).must_include('function oxEscHtml')
    end

    it 'serves node names as inert JSON data on /nodes/stats/datatables' do
      malicious = "'><script>alert(1)</script>"
      stats = mock('Oxidized::Node::Stats')
      stats.stubs(:successes).returns(1)
      stats.stubs(:failures).returns(0)
      stats.stubs(:get).returns(nil)
      node = mock('Oxidized::Node')
      node.stubs(:name).returns(malicious)
      node.stubs(:stats).returns(stats)
      @nodes.stubs(:to_a).returns([node])

      get '/nodes/stats/datatables', {
        draw: '1', start: '0', length: '20',
        'search[value]' => '',
        'order[0][column]' => '0', 'order[0][dir]' => 'asc'
      }

      _(last_response.ok?).must_equal true
      _(last_response.content_type).must_include('application/json')
      result = JSON.parse(last_response.body)
      _(result['data'].first['name']).must_equal malicious
    end
  end

  describe 'config content encoding' do
    it 'encodes script tags in device config on /node/version/view' do
      payload = '<script>alert(1)</script>'
      @nodes.expects(:get_version).with('router1', '', 'abc123').returns(payload)

      get '/node/version/view?node=router1&group=&oid=abc123&epoch=0&num=1'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('&lt;script&gt;alert(1)&lt;/script&gt;')
      _(last_response.body).wont_include('<script>alert(1)</script>')
    end

    it 'encodes script tags in diff output on /node/version/diffs' do
      payload_patch = "- <script>alert(1)</script>\n+ safe line\n"
      versions = [{ oid: 'C006', time: Time.parse('2025-02-05 19:49:00 +0100') }]
      @nodes.expects(:version).with('router1', nil).returns(versions)
      @nodes.expects(:get_diff).with('router1', '', 'C006', nil).returns(
        { patch: payload_patch, stat: [1, 1] }
      )

      get '/node/version/diffs?node=router1&group=&oid=C006&epoch=0&num=1'

      _(last_response.ok?).must_equal true
      _(last_response.body).must_include('&lt;script&gt;alert(1)&lt;/script&gt;')
      _(last_response.body).wont_include('<script>alert(1)</script>')
    end
  end
end
