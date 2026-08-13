use Template::Jinja2;

use App::Ariza::Resources;
use App::Ariza::Tools;

unit class App::Ariza::Update;

our constant UPDATE-PROTOCOL-VERSION is export = 1;
our constant UPDATE-HANDOFF-EXIT is export = 75;
our constant UPDATE-CHECK-INTERVAL is export = 604_800;
our constant UPDATE-VERSION-REGEX is export =
    /^ <[0..9]>+ '.' <[0..9]>+ '.' <[0..9]>+ $/;

my constant TEMPLATE = 'templates/update-coordinator.raku.j2';

our sub valid-update-version(Str:D $version --> Bool:D) is export {
    so $version ~~ UPDATE-VERSION-REGEX
}

our sub compare-update-versions(Str:D $left, Str:D $right --> Order:D) is export {
    die "ariza: update version '$left' must match X.Y.Z"
        unless valid-update-version($left);
    die "ariza: update version '$right' must match X.Y.Z"
        unless valid-update-version($right);
    for $left.split('.') Z $right.split('.') -> ($a, $b) {
        my $aa = $a.subst(/^ '0'+ /, '') || '0';
        my $bb = $b.subst(/^ '0'+ /, '') || '0';
        return More if $aa.chars > $bb.chars;
        return Less if $aa.chars < $bb.chars;
        return More if $aa gt $bb;
        return Less if $aa lt $bb;
    }
    Same
}

#| The coordinator and platform-private installer locations inside a bundle.
method coordinator-rel(--> Str) { 'libexec/ariza/update.raku' }

method installer-rel(Str:D $slug --> Str) {
    $slug.starts-with('windows-')
        ?? 'libexec/ariza/install.ps1'
        !! 'libexec/ariza/install.sh'
}

#| Quote one build-time value as a single-quoted Raku string literal.
#| Configuration strings are data, never generated source.
method raku-quote(Str:D $value --> Str) {
    "'" ~ $value
        .subst('\\', '\\\\', :g)
        .subst("'", "\\'", :g)
        .subst("\r", '\\r', :g)
        .subst("\n", '\\n', :g)
        .subst("\t", '\\t', :g)
      ~ "'"
}

#| Render-time facts for the bundle-private, App::Ariza-free coordinator.
#| Paths are bundle-relative and the installer path is selected here so the
#| generated program never has to infer its platform at run time.
method context(
    Str:D :$app-name!,
    Str:D :$app-exec!,
    Str:D :$app-display!,
    Str:D :$app-version!,
    Str:D :$repo!,
    Str:D :$slug!,
    --> Hash
) {
    die "ariza: update repository must be an owner/name GitHub repository"
        unless $repo ~~ /^ <[A..Za..z0..9_.-]>+ '/' <[A..Za..z0..9_.-]>+ $/;
    die "ariza: update-enabled version '$app-version' is not x.y.z"
        unless valid-update-version($app-version);

    my %values =
        app_name      => $app-name,
        app_exec      => $app-exec,
        app_display   => $app-display,
        app_version   => $app-version,
        repo          => $repo,
        installer_rel => self.installer-rel($slug),
    ;
    %values.map({ .key ~ '_q' => self.raku-quote(.value) }).Hash
}

method render(*%ctx --> Str) {
    my $out = Template::Jinja2.new
        .from-string(resource(TEMPLATE).slurp)
        .render(|%ctx);
    $out ~= "\n" unless $out.ends-with("\n");
    $out
}

#| Stage only the coordinator. The exact-candidate installer is supplied by
#| the platform installer work and lives at the already-baked path returned in
#| C<installer-rel>; launcher integration is deliberately a separate step.
method write(
    IO() :$bundle-dir!,
    Str:D :$app-name!,
    Str:D :$app-exec!,
    Str:D :$app-display!,
    Str:D :$app-version!,
    Str:D :$repo!,
    Str:D :$slug!,
    --> Hash
) {
    my %ctx = self.context(:$app-name, :$app-exec, :$app-display,
                           :$app-version, :$repo, :$slug);
    my $path = ensure-dir($bundle-dir.add('libexec').add('ariza'))
        .add('update.raku');
    $path.spurt(self.render(|%ctx));
    $path.chmod(0o644);
    %(
        coordinator => $path,
        installer   => $bundle-dir.add(self.installer-rel($slug)),
    )
}

=begin pod

=head1 NAME

App::Ariza::Update - render the bundle-private update coordinator

=head1 DESCRIPTION

This is build-time code only. It bakes application identity, current version,
repository and the platform-local installer path into one core-only Raku
program at C<libexec/ariza/update.raku>. The generated program has no run-time
dependency on App::Ariza.

=end pod
