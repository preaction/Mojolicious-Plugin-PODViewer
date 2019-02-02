package Mojolicious::Plugin::PODViewer;
our $VERSION = '0.005';
# ABSTRACT: POD renderer plugin

=encoding utf8

=head1 SYNOPSIS

  # Mojolicious (with documentation browser under "/perldoc")
  my $route = $app->plugin('PODViewer');
  my $route = $app->plugin(PODViewer => {name => 'foo'});
  my $route = $app->plugin(PODViewer => {preprocess => 'epl'});

  # Mojolicious::Lite (with documentation browser under "/perldoc")
  my $route = plugin 'PODViewer';
  my $route = plugin PODViewer => {name => 'foo'};
  my $route = plugin PODViewer => {preprocess => 'epl'};

  # Without documentation browser
  plugin PODViewer => {no_perldoc => 1};

  # foo.html.ep
  %= pod_to_html "=head1 TEST\n\nC<123>"

  # foo.html.pod
  =head1 <%= uc 'test' %>

  # ojo one-liner (documentation browser for the code in folder "lib")
  perl -Ilib -Mojo -E'plugin "PODViewer"; a->start' daemon

=head1 DESCRIPTION

L<Mojolicious::Plugin::PODViewer> is a renderer for Perl's POD (Plain
Old Documentation) format. It includes a browser to browse the Perl
module documentation as a website.

This is a fork of the former Mojolicious::Plugin::PODRenderer.

=head1 OPTIONS

L<Mojolicious::Plugin::PODViewer> supports the following options.

=head2 name

  # Mojolicious::Lite
  plugin PODViewer => {name => 'foo'};

Handler name, defaults to C<pod>.

=head2 route

The L<route|Mojolicious::Routes::Route> to add documentation to. Defaults to
C<< $app->routes->any('/perldoc') >>. The new route will have a name of
C<plugin.podviewer>.

=head2 default_module

The default module to show. Defaults to C<Mojolicious::Guides>.

=head2 allow_modules

An arrayref of regular expressions that match modules to allow. At least
one of the regular expressions must match. Disallowed modules will be
redirected to the appropriate page on L<http://metacpan.org>.

=head2 layout

The layout to use. Defaults to C<podviewer>.

=head2 no_perldoc

  # Mojolicious::Lite
  plugin PODViewer => {no_perldoc => 1};

Disable L<Mojolicious::Guides> documentation browser that will otherwise be
available under C</perldoc>.

=head2 preprocess

  # Mojolicious::Lite
  plugin PODViewer => {preprocess => 'epl'};

Name of handler used to preprocess POD, defaults to C<ep>.

=head1 HELPERS

L<Mojolicious::Plugin::PODViewer> implements the following helpers.

=head2 pod_to_html

  %= pod_to_html '=head2 lalala'
  <%= pod_to_html begin %>=head2 lalala<% end %>

Render POD to HTML without preprocessing.

=head1 TEMPLATES

L<Mojolicious::Plugin::PODViewer> bundles the following templates. To
override this template with your own, create a template with the same name.

=head2 podviewer/perldoc.html.ep

This template displays the POD for a module. The HTML for the documentation
is in the C<perldoc> content section (C<< <%= content 'perldoc' %> >>).
The template has the following stash values:

=over

=item cpan

A link to L<http://metacpan.org> for the current module.

=item module

The current module, with parts separated by C</>.

=item perlmodule

The current module, with parts separated by C<::>.

=item topics

An array of arrays of topics in the documentation. Each inner array is
a set of pairs of C<link text> and C<link href> suitable to be passed
directly to the C<link_to> helper. New topics are started by a C<=head1>
tag, and include all lower-level headings.

=back

=head2 layouts/podviewer.html.ep

The layout for rendering POD pages. Use this to add stylesheets,
JavaScript, and additional navigation. Set the C<layout> option to
change this template.

=head1 METHODS

L<Mojolicious::Plugin::PODViewer> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  my $route = $plugin->register(Mojolicious->new);
  my $route = $plugin->register(Mojolicious->new, {name => 'foo'});

Register renderer and helper in L<Mojolicious> application.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<https://mojolicious.org>.

=cut
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::Asset::File;
use Mojo::ByteStream;
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::URL;
use Pod::Simple::XHTML;
use Pod::Simple::Search;

sub register {
  my ($self, $app, $conf) = @_;

  my $preprocess = $conf->{preprocess} || 'ep';
  $app->renderer->add_handler(
    $conf->{name} || 'pod' => sub {
      my ($renderer, $c, $output, $options) = @_;
      $renderer->handlers->{$preprocess}($renderer, $c, $output, $options);
      $$output = _pod_to_html($$output) if defined $$output;
    }
  );

  $app->helper(
    pod_to_html => sub { shift; Mojo::ByteStream->new(_pod_to_html(@_)) });

  # Perldoc browser
  return undef if $conf->{no_perldoc};

  push @{ $app->renderer->classes }, __PACKAGE__;
  my $default_module = $conf->{default_module} // 'Mojolicious::Guides';
  $default_module =~ s{::}{/}g;

  my $defaults = {
      module => $default_module,
      ( $conf->{layout} ? ( layout => $conf->{layout} ) : () ),
      allow_modules => $conf->{allow_modules} // [ qr{} ],
  };
  my $route = $conf->{route} ||= $app->routes->any( '/perldoc' );
  return $route->any( '/:module' =>
      $defaults => [module => qr/[^.]+/] => \&_perldoc,
  )->name('plugin.podviewer');
}

sub _indentation {
  (sort map {/^(\s+)/} @{shift()})[0];
}

sub _html {
  my ($c, $src) = @_;

  # Rewrite links
  my $dom  = Mojo::DOM->new(_pod_to_html($src));
  my $base = 'https://metacpan.org/pod/';
  $dom->find('a[href]')->map('attr')->each(sub {
    if ($_->{href} =~ m!^\Q$base\E([:\w]+)!) {
      my $module = $1;
      return undef
        unless grep { $module =~ /$_/ } @{ $c->stash('allow_modules') || [] };
      $_->{href} =~ s{^\Q$base$module\E}{$c->url_for(module => $module)}e;
      $_->{href} =~ s!::!/!gi
    }
  });

  # Rewrite code blocks for syntax highlighting and correct indentation
  for my $e ($dom->find('pre > code')->each) {
    my $attrs = $e->parent->attr;
    my $class = $attrs->{class};
    my $parent_class = 'codesample rounded';
    $attrs->{class} = defined $class ? "$class $parent_class" : $parent_class;

    next if (my $str = $e->content) =~ /^\s*(?:\$|Usage:)\s+/m;
    next unless $str =~ /[\$\@\%]\w|-&gt;\w|^use\s+\w/m;

    $attrs = $e->attr;
    $class = $attrs->{class};
    $attrs->{class} = defined $class ? "$class prettyprint" : 'prettyprint';
  }

  # Rewrite headers
  my $toc = Mojo::URL->new->fragment('toc');
  my @topics;
  for my $e ($dom->find('h1, h2, h3, h4')->each) {

    push @topics, [] if $e->tag eq 'h1' || !@topics;
    my $link = Mojo::URL->new->fragment($e->{id});
    push @{$topics[-1]}, my $text = $e->all_text, $link;
    my $permalink = $c->tag('small', class => 'text-muted', $c->link_to(chr(0x221e) => $link));
    $e->content( $c->link_to($text => $toc) . ' ' . $permalink);
  }

  # Try to find a title
  my $title = 'Perldoc';
  $dom->find('h1 + p')->first(sub { $title = shift->text });

  # Combine everything to a proper response
  $c->content_for(perldoc => "$dom");
  $c->render('podviewer/perldoc', title => $title, topics => \@topics);
}

sub _perldoc {
  my $c = shift;

  # Find module or redirect to CPAN
  my $module = join '::', split('/', $c->param('module'));
  $c->stash(cpan => "https://metacpan.org/pod/$module");
  $c->stash(perlmodule => $module);

  return $c->redirect_to( $c->stash( 'cpan' ) )
    unless grep { $module =~ /$_/ } @{ $c->stash( 'allow_modules' ) || [] };

  my $path
    = Pod::Simple::Search->new->find($module, map { $_, "$_/pods" } @INC);
  return $c->redirect_to($c->stash('cpan')) unless $path && -r $path;

  $c->stash->{layout} //= 'podviewer';
  my $src = path($path)->slurp;
  $c->respond_to(txt => {data => $src}, html => sub { _html($c, $src) });
}

sub _pod_to_html {
  return '' unless defined(my $pod = ref $_[0] eq 'CODE' ? shift->() : shift);

  my $parser = Pod::Simple::XHTML->new;
  $parser->perldoc_url_prefix('https://metacpan.org/pod/');
  $parser->$_('') for qw(html_header html_footer);
  $parser->strip_verbatim_indent(\&_indentation);
  $parser->output_string(\(my $output));
  return $@ unless eval { $parser->parse_string_document("$pod"); 1 };

  return $output;
}

1;
__DATA__

@@ layouts/podviewer.html.ep
<!DOCTYPE html>
<html>
  <head>
    <title><%= title %></title>
    %= tag 'meta', charset => 'UTF-8'
    %= tag 'meta', name => 'viewport', content => 'width=device-width, initial-scale=1, shrink-to-fit=no'
    <%= stylesheet 'https://stackpath.bootstrapcdn.com/bootstrap/4.2.1/css/bootstrap.min.css',
        integrity => 'sha384-GJzZqFGwb1QTTN6wy59ffF1BuGJpLSa9DkKMp0DgiMDm4iYMj70gZWKYbI706tWS',
        crossorigin =>'anonymous' %>
    %= stylesheet begin
      .codesample {
        background-color: #f8f9fa;
        padding: 1em;
      }
    % end
  </head>
  <body>
  %= content
  %= javascript '/mojo/jquery/jquery.js'
  <%= javascript 'https://stackpath.bootstrapcdn.com/bootstrap/4.2.1/js/bootstrap.min.js',
      integrity => 'sha384-B0UglyR+jN6CkvvICOB2joaf5I4l3gm9GU6Hc1og6Ls7i6U/mkkaduKaBhlAXv9k',
      crossorigin => 'anonymous' %>
  %= javascript '/mojo/prettify/run_prettify.js'
  </body>
</html>

@@ podviewer/perldoc.html.ep
<nav class="navbar navbar-expand-sm navbar-dark bg-dark">
  <a class="navbar-brand" href="#">Perldoc</a>
  <button class="navbar-toggler" type="button" data-toggle="collapse" data-target="#navbarText" aria-controls="navbarText" aria-expanded="false" aria-label="Toggle navigation">
    <span class="navbar-toggler-icon"></span>
  </button>
  <div class="collapse navbar-collapse" id="navbarText">
    <div class="navbar-nav mr-auto">
      % my $path;
      % for my $part (split '/', $module) {
        %= tag 'span', class => 'navbar-text', '::' if $path
        % $path .= "/$part";
        %= link_to $part => "/perldoc$path", class => 'nav-link'
      % }
    </div>
    <div class="navbar-nav">
      %= link_to source => '', {format => 'txt'}, class => 'nav-link'
      %= link_to CPAN => $cpan, class => 'nav-link'
    </div>
  </div>
</nav>

<div class="container">
  <h3 class="mt-3 mb-3"><%= $perlmodule %></h3>
  <h1><a id="toc">Contents</a> <a class="btn btn-light btn-sm" data-toggle="collapse" data-target="#topics">hide/show</a></h1>
  <ul class="collapse show list-unstyled" id="topics">
    % for my $topic (@$topics) {
      <li>
        %= link_to splice(@$topic, 0, 2)
        % if (@$topic) {
          <ul>
            % while (@$topic) {
              <li><%= link_to splice(@$topic, 0, 2) %></li>
            % }
          </ul>
        % }
      </li>
    % }
  </ul>

  %= content 'perldoc'
</div>
