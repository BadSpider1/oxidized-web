require_relative '../../spec_helper'
require 'json'

# A live-node stand-in exposing the accessors /node/show reads directly off the
# live Oxidized::Node object (Nodes#show only returns serialized data, which
# carries neither the resolved credentials nor the failure history).
LiveNodeDouble = Struct.new(:name, :auth, :failure_history)

describe 'Oxidized::API::WebApp /node/show credentials and failures' do
  include Rack::Test::Methods

  def app
    Oxidized::API::WebApp
  end

  before do
    @nodes = mock('Oxidized::Nodes')
    app.set(:nodes, @nodes)
    app.set(:configuration, { hide_node_vars: [], hide_credentials: false })
    @serialized = {
      name: 'sw5', full_name: 'sw5', ip: '10.0.0.1', group: nil,
      model: 'ios', last: nil, vars: {}, mtime: 'unknown'
    }
    @nodes.stubs(:show).with('sw5').returns(@serialized)
  end

  it 'shows the resolved username and the password behind a reveal toggle' do
    live = LiveNodeDouble.new('sw5', { username: 'oxidized', password: 's3cr3t!' }, [])
    @nodes.stubs(:to_a).returns([live])

    get '/node/show/sw5'

    _(last_response.ok?).must_equal true
    body = last_response.body
    _(body).must_include 'Host credentials'
    _(body).must_include 'oxidized'
    # the password is delivered in a data attribute for the client-side reveal
    _(body).must_include 'data-password="s3cr3t!"'
    _(body).must_include 'id="togglePassword"'
    # ... but it is not shown in the clear in the cell text
    _(body).must_include '••••••••'
  end

  it 'HTML-escapes a password containing markup in the reveal attribute' do
    live = LiveNodeDouble.new('sw5', { username: 'u', password: 'a"<b>&c' }, [])
    @nodes.stubs(:to_a).returns([live])

    get '/node/show/sw5'

    body = last_response.body
    _(body).wont_include 'a"<b>&c'
    _(body).must_include 'data-password="a&quot;&lt;b&gt;&amp;c"'
  end

  it 'lists per-connection-method failures, newest first' do
    failures = [
      { time: Time.utc(2026, 8, 19, 10, 0, 1), input: 'SSH',
        err_type: 'Net::SSH::AuthenticationFailed', err_reason: 'Authentication failed' },
      { time: Time.utc(2026, 8, 19, 10, 0, 2), input: 'Telnet',
        err_type: 'Errno::ECONNREFUSED', err_reason: 'Connection refused' }
    ]
    live = LiveNodeDouble.new('sw5', {}, failures)
    @nodes.stubs(:to_a).returns([live])

    get '/node/show/sw5'

    body = last_response.body
    _(body).must_include 'Recent failures'
    _(body).must_include 'Telnet'
    _(body).must_include 'Net::SSH::AuthenticationFailed'
    _(body).must_include 'Connection refused'
    # failure_history is oldest-first; the view shows newest-first, so the
    # Telnet row (10:00:02) precedes the SSH row (10:00:01)
    _(body.index('Telnet') < body.index('Net::SSH::AuthenticationFailed')).must_equal true
  end

  it 'shows a friendly message when there are no failures' do
    live = LiveNodeDouble.new('sw5', {}, [])
    @nodes.stubs(:to_a).returns([live])

    get '/node/show/sw5'

    _(last_response.body).must_include 'No recorded failures.'
  end

  it 'includes credentials and failures in the JSON representation' do
    failures = [{ time: Time.utc(2026, 8, 19, 10, 0, 1), input: 'SSH',
                  err_type: 'Net::SSH::AuthenticationFailed', err_reason: 'boom' }]
    live = LiveNodeDouble.new('sw5', { username: 'oxidized', password: 's3cr3t!' }, failures)
    @nodes.stubs(:to_a).returns([live])

    get '/node/show/sw5.json'

    _(last_response.ok?).must_equal true
    data = JSON.parse(last_response.body)
    _(data['credentials']['username']).must_equal 'oxidized'
    _(data['credentials']['password']).must_equal 's3cr3t!'
    _(data['failures'].length).must_equal 1
    _(data['failures'][0]['input']).must_equal 'SSH'
    _(data['failures'][0]['err_type']).must_equal 'Net::SSH::AuthenticationFailed'
    _(data['failures'][0]['err_reason']).must_equal 'boom'
    _(data['failures'][0]['time']).must_equal Time.utc(2026, 8, 19, 10, 0, 1).to_i
  end

  it 'finds the live node when the page is addressed by IP' do
    ip_double = Struct.new(:name, :ip, :auth, :failure_history)
                      .new('core-sw1', '10.0.0.1', { username: 'oxidized', password: 'byip!' }, [])
    @nodes.stubs(:show).with('10.0.0.1').returns(@serialized)
    @nodes.stubs(:to_a).returns([ip_double])

    get '/node/show/10.0.0.1'

    _(last_response.ok?).must_equal true
    _(last_response.body).must_include 'data-password="byip!"'
  end

  it 'gracefully handles an unknown live node (serialized data only)' do
    @nodes.stubs(:to_a).returns([])

    get '/node/show/sw5'

    _(last_response.ok?).must_equal true
    body = last_response.body
    _(body).must_include 'Host credentials'
    _(body).must_include '(not set)'
    _(body).must_include 'No recorded failures.'
  end

  describe 'hide_credentials' do
    before do
      app.set(:configuration, { hide_node_vars: [], hide_credentials: true })
    end

    it 'suppresses the password in the HTML view' do
      live = LiveNodeDouble.new('sw5', { username: 'oxidized', password: 's3cr3t!' }, [])
      @nodes.stubs(:to_a).returns([live])

      get '/node/show/sw5'

      body = last_response.body
      _(body).wont_include 's3cr3t!'
      # no password is emitted into the reveal attribute (the JS still
      # references the attribute name, so match the attribute form)
      _(body).wont_include 'data-password="'
      _(body).must_include 'hide_credentials'
    end

    it 'omits the password from the JSON representation' do
      live = LiveNodeDouble.new('sw5', { username: 'oxidized', password: 's3cr3t!' }, [])
      @nodes.stubs(:to_a).returns([live])

      get '/node/show/sw5.json'

      data = JSON.parse(last_response.body)
      _(data['credentials']).must_equal({ 'hidden' => true })
      _(last_response.body).wont_include 's3cr3t!'
    end
  end
end
