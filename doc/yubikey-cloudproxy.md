# YubiKey met de privacyIDEA Credential Provider en CloudProxy

*Stand van zaken november 2026.*

De privacyIDEA Credential Provider ondersteunt in deze versie FIDO2-sleutels, zoals een
YubiKey, via WebAuthn en passkeys. Of je dat kunt gebruiken, hangt af van de server waarmee
de credential provider praat. Met de huidige CloudProxy-backend werkt het nog niet.

## Waarom het met CloudProxy nog niet werkt

De credential provider praat met de privacyIDEA-compatibele REST-API van **CloudProxy**,
niet met een echte privacyIDEA-server. `handlePiValidateCheck` in
`AuthenticatieService/AsCloudProxy/RestLib/RestDelegates.cs`:

- negeert de meegestuurde `pass`;
- doet `AuthProxy.FindUserInAdOrUserdatabaseAndAuthenticate`, in de praktijk een
  KeyApp-push, en wacht op ACK of NACK;
- geeft `value: true/false` terug, bij een ACK aangevuld met de offline-HOTP-gegevens
  (`auth_items.offline`).

De FIDO-route in de credential provider start pas als de server op de eerste
`/validate/check` een **WebAuthn-challenge** terugstuurt: een `multi_challenge` met een
`webAuthnSignRequest` en een `transaction_id`. Daarna verwacht de credential provider dat
een tweede `/validate/check` de handtekening controleert. CloudProxy doet geen van beide.

CloudProxy heeft wel een `WebAuthnManager` (`UtilsLib/WebAuthnManager.cs`), maar die wordt
alleen gebruikt voor de inlog in de GUI en via de Authorization Server/OIDC, niet in de
REST-API.

## Route A: eerst testen met een echte privacyIDEA-server

Zo zie je het snelst de YubiKey in actie. De broncode van privacyIDEA staat in
`privacyidea-server/`, met een `compose-dev.yml` voor een ontwikkelomgeving.

1. **YubiKey voorbereiden.** Stel een FIDO2-PIN in:

   ```bash
   ykman fido access change-pin
   ```

2. **privacyIDEA instellen.**
   - Stel de WebAuthn-policies `webauthn_relying_party_id` en
     `webauthn_relying_party_name` in.
   - Rol voor de gebruiker een WebAuthn- of passkey-token uit met de YubiKey, via de
     web-UI.
   - Voor offline gebruik: zet bij dat token *Application → Offline* aan. Het token moet
     daarna één keer online met de credential provider gebruikt worden om de
     offline-gegevens op te halen.
   - Optioneel: `passkey_trigger_by_pin=true`, zodat passkeys zich gedragen als
     WebAuthn-tokens en via de gebruikersnaam getriggerd kunnen worden.

3. **Credential provider instellen** (register, onder de sleutel van de credential
   provider):

   | Waarde | Instelling | Waarom |
   |---|---|---|
   | `hostname`, `path` | naar de privacyIDEA-server | |
   | `two_step_send_empty_password` | `1` | Verplicht: anders wordt er geen challenge opgevraagd |
   | `webauthn_preferred` | `1` (optioneel) | Meteen door naar "raak je sleutel aan" in plaats van eerst het OTP-veld |
   | `passkey_first_step` | `1` (optioneel) | Direct een passkey-login zonder gebruikersnaam. Zonder deze instelling kan dat via de link onderaan de eerste stap |
   | `trusted_rpids` | lijst (optioneel) | Alleen FIDO-operaties toestaan voor deze RP ID's |

4. **Inloggen.**
   - **Lokaal** praat de credential provider via libfido2 direct met de YubiKey over USB.
   - **Via RDP** gebruikt hij Windows Hello, dat de sleutel van de lokale PC doorgeeft.

Na het aanraken van de sleutel kun je de handeling niet meer annuleren. De sleutel houdt de
controle tot de handeling klaar is of verloopt.

## Route B: CloudProxy uitbreiden

Hiermee werkt de YubiKey met de eigen backend, ook offline. Dit is de logische route voor
echt gebruik.

Wat er moet gebeuren:

- **Eerste aanroep:** laat `/validate/check` voor gebruikers met een FIDO2-credential een
  WebAuthn-challenge teruggeven in privacyIDEA-formaat: `multi_challenge`,
  `webAuthnSignRequest` en `transaction_id`.
- **Tweede aanroep:** verifieer de aanroep met `transaction_id`, `credentialid`,
  `clientdata`, `signaturedata` en `authenticatordata` via de bestaande `WebAuthnManager`.
- **Offline:** stuur de public key mee in `auth_items.offline`, zodat de credential
  provider de sleutel ook zonder verbinding kan controleren.

Aandachtspunten:

- `WebAuthnManager` werkt alleen onder **net8.0**. Onder net472 is het een stub, omdat
  Fido2/Fido2.Models geen net472-variant leveren.
- De credential provider gebruikt de **computernaam als origin**, terwijl
  `WebAuthnManager` de RP ID nu juist afleidt uit de origin. Voor de credential provider is
  een vaste, geconfigureerde RP ID nodig.

## Route C: de YubiKey als HOTP-"toetsenbord"

Een YubiKey kan in een OTP-slot een OATH-HOTP-code intypen als je hem aanraakt.
Offline-HOTP in CloudProxy (`UtilsLib/OfflineHotp.cs`) gebruikt het TOTP-geheim van de
gebruiker, maar dan op basis van een teller. Als je dat geheim in de YubiKey zet, heb je
**offline** inloggen met één aanraking, zonder typen.

Er zijn wel nadelen:

- **Online heeft het geen effect**, want CloudProxy negeert de `pass` en doet een
  KeyApp-push.
- **Het geheim staat op twee plekken:** het KeyApp-geheim staat dan ook op de YubiKey.
- **De teller moet in het venster blijven.** De teller van de YubiKey moet binnen het
  venster van de offline-controle blijven (`offline_try_window`, standaard 10 stappen).

Dit is eerder een handigheidje dan een nette oplossing.

## Advies

- **Eerst kennismaken:** gebruik route A om de werking met de YubiKey te zien.
- **Echt in gebruik nemen:** kies route B.
