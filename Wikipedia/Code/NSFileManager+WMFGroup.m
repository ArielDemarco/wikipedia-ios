#import <WMF/NSFileManager+WMFGroup.h>
#import "WMFQuoteMacros.h"

NSString *const WMFApplicationGroupIdentifier = @QUOTE(WMF_APP_GROUP_IDENTIFIER);

@implementation NSFileManager (WMFGroup)

- (nonnull NSURL *)wmf_containerURL {
    NSURL *shared = [self containerURLForSecurityApplicationGroupIdentifier:WMFApplicationGroupIdentifier];
    if (shared != nil) {
        return shared;
    }
    // Parche para poder medir esta app fuera del equipo de Wikimedia.
    //
    // El app group requiere un App ID registrado en el portal, que a su vez
    // requiere una cuenta autenticada en Xcode. Sin eso el container es nil y la
    // app crashea al arrancar, antes de que se pueda medir nada.
    //
    // The app's own container works just as well: the only thing lost is
    // sharing data with the extensions, which do not run in a measurement build.
    return [[self URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
}

- (nonnull NSString *)wmf_containerPath {
    return [[self wmf_containerURL] path];
}

@end
