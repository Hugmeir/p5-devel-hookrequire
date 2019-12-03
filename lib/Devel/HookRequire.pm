package Devel::HookRequire;
use DynaLoader;
sub DEBUG () { $ENV{DEBUG_ALL} // $ENV{DEBUG_Devel_HookRequire} }

our $VERSION = '0.01';
our @ISA     = 'DynaLoader';

__PACKAGE__->bootstrap;

=begin
sub Devel::HookRequire::execute_die_hooks {
    my ($file, $message)= @_;
    $message= $_->($file,$message) for @die_hooks;
    return $message;
}

sub _generate_new_sigdie_callback {
    my ($file, $old_sig) = @_;
    my $cb;
    eval {
        $cb = sub {
            my $orig_error = $_[0];
            my $message    = $Devel::HookRequire::IN_RECURSION ? $orig_error : undef;
            local $Devel::HookRequire::IN_RECURSION = 1;
            $message     //=  Devel::HookRequire::execute_die_hooks($file, $orig_error) // $orig_error;

            # check if there was already an installed handler, and if so fire it off as well
            if ($old_sig) {
                # but sanity check its a ref at least!
               if (ref $old_sig) {
                   $old_sig->($message);
               } elsif ( Devel::HookRequire::DEBUG() ) {
                   CORE::warn(CORE::sprintf "got non ref sig die callback: %s", $old_sig);
               }
            }
            # NOTE: we cannot goto &CORE::die here, as that would undo the IN_RECURSION and
            # possibly kill us.
            CORE::die($message);
        };
        1;
    } or do {
        my $e = $@ || 'Zombie error';
        warn "Devel::HookRequire: Error caught when creating our new __DIE__ handler -- will fall back to any existing handler:\n$e";
        $cb = $old_sig;
    };
    return $cb;
}
=cut

1;
__END__
=encoding utf-8

=pod

=head1 NAME

Devel::HookRequire - ...

=head1 DESCRIPTION

...

=cut


