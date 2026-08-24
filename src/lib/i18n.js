// ============================================================================
//  NOTI Calling — parcours client en FR / EN / ES
//
//  Retour terrain : « la langue ne change que le bouton ; si vous proposez
//  plusieurs langues, allez au bout ». Tout le texte que l'application écrit
//  elle-même côté client est donc ici, dans les trois langues.
//
//  Ce qui reste dans la langue de l'établissement, et c'est normal : les noms
//  de catégories et de produits saisis par le staff (la carte). Le staff peut
//  déjà traduire chaque produit dans l'éditeur de carte ; à défaut, le libellé
//  d'origine est affiché.
//
//  L'espace staff, lui, reste en français : il n'est pas exposé aux clients.
//
//  Règle : toute clé absente d'une langue retombe sur le français (voir dict).
//  Une valeur peut être une fonction quand il faut accorder ou insérer.
// ============================================================================

export const LANGS = ['fr', 'en', 'es']

export const LANG_LABEL = { fr: 'Français', en: 'English', es: 'Español' }

const s = (n) => (n > 1 ? 's' : '')

export const T = {
  // -------------------------------------------------------------- FRANÇAIS
  fr: {
    // Communs
    welcome: 'Bienvenue',
    start: 'Commander',
    order: 'Commander',
    cart: 'Panier',
    total: 'Total',
    send: 'Envoyer la commande',
    sending: 'Envoi…',
    soldOut: 'Épuisé',
    note: 'Note pour le bar',
    promo: 'Code promo',
    pickupCode: 'Code de retrait',
    save: 'Enregistrer',
    sendShort: 'Envoyer',
    add: 'Ajouter',
    continue: 'Continuer',
    removeCode: 'Retirer',
    activate: 'Activer',
    seeMenu: 'Voir la carte',
    see: 'Voir',
    loadingMenu: 'Chargement de la carte…',
    opening: 'Ouverture…',
    backSoon: 'Bon retour parmi nous…',
    unknownQr: 'QR code inconnu',

    // Règlement au bar
    payTitle: 'Règlement au bar',
    paySub: 'Aucun paiement en ligne. Vous réglez au comptoir en retirant votre commande.',

    // Accueil
    ordersClosed: 'Les commandes sont fermées pour le moment.',
    closedStillHere: 'La carte reste consultable, et l’équipe peut toujours vous écrire.',
    allMenuHere: 'Toute la carte se commande ici, depuis votre téléphone.',
    noQueueStrong: 'récupérer',
    noQueueBottles: 'bouteilles',
    noQueue: (recup, bouteilles) =>
      `Plus besoin de faire la queue : vous ne passez au bar que pour ${recup} votre commande, et pour les ${bouteilles} (servies immédiatement).`,
    step1t: 'Vous commandez ici',
    step1s: 'Toute la carte, sans faire la queue',
    step2t: 'Le bar prépare',
    step2s: 'Vous êtes prévenu·e dès que c’est prêt — restez où vous êtes',
    step3t: 'Vous retirez au bar',
    step3s: 'Avec votre code, sans attendre',
    step4t: 'Vous réglez sur place',
    step4s: 'Au comptoir, comme d’habitude',

    // Identification
    identify: 'Faisons connaissance',
    identifySub: 'Pour commander : vos coordonnées, pour vous appeler au retrait et vous tenir informé·e.',
    firstName: 'Prénom',
    lastName: 'Nom',
    phone: 'Téléphone',
    postalCode: 'Code postal',
    birthdate: 'Date de naissance',
    email: 'E-mail',
    instagram: 'Instagram',
    optional: 'Optionnel',
    addOptional: '+ E-mail / Instagram (optionnel — complétable plus tard)',
    cgu: 'En commandant, vous acceptez nos CGU — retrait et règlement au bar obligatoires.',
    dataEu: 'Données hébergées dans l’Union européenne. Aucun paiement en ligne.',
    errNames: 'Prénom et nom sont obligatoires.',
    errPhone: 'Numéro de téléphone obligatoire.',
    errPostal: 'Code postal obligatoire.',
    errBirth: 'Date de naissance obligatoire.',
    errEmail: 'Adresse e-mail invalide.',
    errBirthInvalid: 'Date de naissance invalide — vérifiez le jour, le mois et l’année.',

    // Reconnaissance
    gladToSeeYou: 'Ravi de vous revoir',
    backAgain: 'Bon retour parmi nous',
    secondNight: 'Deuxième soirée avec nous — content de vous retrouver.',
    nNights: (n) => `${n} soirées passées avec nous. Merci de votre fidélité.`,
    vipStatus: 'STATUT VIP',
    unpaidPast:
      'Une commande d’une soirée précédente est restée impayée. Merci de régulariser auprès du bar — l’équipe vous accompagnera.',

    // Navigation
    backHome: 'Retour à l’accueil',
    backToTop: 'Remonter en haut',
    back: 'Retour',

    // Assistant
    assistantOpen: 'Besoin d’aide ?',
    assistantTitle: 'Assistant Noti',
    assistantIntro: 'Une question sur la carte, votre commande ou vos crédits ? Je suis là.',
    assistantPlaceholder: 'Écrivez votre question…',
    assistantSend: 'Envoyer',
    assistantThinking: 'Réponse en cours…',
    assistantError: 'L’assistant est momentanément indisponible. Un membre de l’équipe peut vous aider via Messages.',
    assistantSlowDown: 'Beaucoup de questions d’un coup ! Laissez-moi quelques instants et reposez votre question.',
    tabMenu: 'La carte',
    tabOrders: 'Mes commandes',
    tabMessages: 'Messages',
    myAccount: 'Mon espace client',

    // Bandeaux
    completeProfile: 'Complétez votre profil',
    fPostal: 'code postal',
    fBirth: 'date de naissance',
    fEmail: 'e-mail',
    fInstagram: 'Instagram',
    goToAccount: 'à faire dans votre espace client',
    blockedStrong: 'Vous avez une commande prête à retirer.',
    blockedRest: 'Récupérez-la d’abord au bar avant de pouvoir passer une nouvelle commande — code',
    newMessages: (n) => `${n} nouveau${n > 1 ? 'x' : ''} message${s(n)} de l’équipe`,
    nothingHere: 'Rien dans cette sélection',
    pushOk: 'Vous serez prévenu même écran verrouillé.',
    pushKo: 'Notifications refusées.',
    profileSaved: 'Profil mis à jour.',
    reviewThanks: 'Merci pour votre retour !',

    // Carte produit
    popular: 'POPULAIRE',
    priceFrom: (p) => `dès ${p}`,
    pickupFirst: 'Retirez d’abord votre commande prête',

    // Choix format / options
    format: 'Format',
    requiredCaps: 'OBLIGATOIRE',
    optionalCaps: 'OPTIONNEL',
    maxCaps: 'MAX',
    included: 'inclus',
    chooseFirst: (name) => `Choisissez : ${name}`,

    // Crédits, forfaits, codes
    creditsIntroTitle: 'Vos crédits sont prêts',
    creditsIntroYouHave: (n) => `Vous avez ${n} crédit${s(n)}`,
    creditsIntroSoft: '1 crédit = 1 soft',
    creditsIntroAlcohol: '2 crédits = 1 conso alcoolisée',
    creditsIntroHow:
      'Ils se déduisent tout seuls quand vous ajoutez un article au panier. Rien à faire de plus.',
    creditsIntroCta: 'Voir la carte',
    creditBadge: 'Avec vos crédits',
    myCredits: 'Mes crédits',
    nAvailable: (n) => `${n} disponible${s(n)}`,
    nCredits: (n) => `${n} crédit${s(n)}`,
    menuItem: 'article de la carte',
    ofChoice: (cat) => `${cat} au choix`,
    creditAuto:
      'Vos crédits se déduisent tout seuls quand vous ajoutez un article au panier. 1 crédit = 1 soft, 2 crédits = 1 conso alcoolisée.',
    promoPlaceholder: 'Réduction, crédit ou forfait',
    promoCta: '🎟️ Un code promo ou un forfait de groupe ? Activez-le ici',
    creditsAdded: 'Crédits ajoutés — retrouvez-les en haut de la carte !',
    passActivated: 'Forfait activé !',
    codeActivated: 'Code activé !',
    codeAlreadyUsed: 'Ce code est déjà utilisé — vos crédits n’ont pas changé.',
    activeCode: 'Code actif',
    activePass: '🎟️ Forfait actif',
    creditsLeft: (n) => `${n} crédit${s(n)} restant${s(n)}`,
    foodToken: 'Jeton food',
    tokenAvailable: 'disponible',
    tokenUsed: 'utilisé',
    convertToken: 'Convertir mon jeton food en 2 crédits (1 alcool ou 2 softs)',
    tokenConverted: 'Jeton food converti en 2 crédits.',
    creditsEmpty: 'Crédits épuisés',
    nSofts: (n) => `${n} soft${s(n)}`,
    nAlcohols: (n) => `${n} alcool${s(n)}`,
    plusOneSoft: ' + 1 soft',
    orNSofts: (n) => `, ou ${n} soft${s(n)}`,
    catFood: 'Plat',
    catBottle: 'Bouteille',
    catDrink: 'Boisson',

    // Espace client
    logout: 'Se déconnecter de cet appareil',
    logoutHint:
      'Vous repasserez par l’écran d’accueil et le formulaire d’inscription. Rien n’est perdu : en indiquant le même numéro de téléphone, vous retrouvez votre fiche, vos commandes et vos crédits.',
    logoutConfirm:
      'Se déconnecter de cet appareil ? Vous devrez ressaisir vos informations pour commander.',
    clientSpace: 'Espace client',
    yourInfo: 'Vos informations',
    myNights: (n) => `${n} soirée${s(n)} avec nous`,
    firstNight: 'Première soirée avec nous',
    myOrdersHere: 'Vos commandes de ce soir',
    noOrdersHere: 'Aucune commande ce soir pour l’instant.',
    creditsNone: 'Aucun crédit en cours',

    // Panier
    emptyCart: 'Panier vide',

    // Validation
    validateOrder: 'Valider la commande',
    notePlaceholder: 'Sans glace, peu sucré, allergie…',
    checkingCode: (c) => `Vérification du code ${c}…`,
    creditsLeftAfter: (n) =>
      n > 0
        ? `Il vous restera ${n} crédit${n > 1 ? 's' : ''} après cette commande.`
        : 'Vos crédits seront épuisés après cette commande.',
    codeApplied: (c, v) => `Code ${c} — réduction de ${v} appliquée ci-dessous.`,
    codeInvalid: (c) => `Code ${c} invalide, expiré, épuisé ou panier insuffisant pour ce code.`,
    readyIn: (min) => `Prête dans environ ${min} min.`,
    pickup5:
      'Merci de récupérer votre commande dans les 5 minutes une fois prête — elle reste due même si elle n’est pas retirée.',

    // Messages
    noMessages: 'Aucun message pour l’instant',
    noMessagesSub: 'Les annonces de la soirée et les messages qui vous sont adressés apparaîtront ici.',
    msgForYou: 'Message pour vous',
    msgOrder: 'Suivi de commande',
    seeMyOrder: 'Voir ma commande',
    msgUrgent: 'Message urgent',
    newUrgent: (n) => `${n} message${s(n)} urgent${s(n)}`,
    announcement: 'Annonce de la soirée',
    markRead: 'Marquer comme lu',

    // Commandes
    noOrders: 'Aucune commande pour l’instant',
    noOrdersSub: 'Vos commandes de la soirée apparaîtront ici.',
    notifOn: '✓ Notifications activées',
    notifCta: 'Me prévenir quand c’est prêt',
    showCodeAtBar: 'Présentez ce code au bar et réglez sur place',
    orderedAt: (h) => `Commande de ${h}`,

    // Retard : le compte à rebours est passé et la commande n'est toujours pas
    // prête. Plutôt qu'un compteur négatif ou un silence, on assume le retard
    // avec le ton de la maison. La dernière ligne sert aux gros retards.
    delayNotes: [
      'T’as le temps d’aller danser 💃 ta commande n’est pas encore prête.',
      'Le bar est pris d’assaut 🍸 encore un morceau ou deux et c’est à toi.',
      'Petit retard, grande soif — on accélère, promis.',
      'On n’a pas oublié ta commande, il y a juste du monde devant 🙃',
      'Ça prend un peu plus longtemps que prévu. Profites-en pour refaire le monde.',
      'Le shaker chauffe ! Encore un instant et c’est prêt.',
    ],
    delayNoteLate: 'Là, on avoue, ça traîne vraiment 😅 toute l’équipe est dessus.',
    delayBadge: 'Un peu de retard',
    unpaidOrder:
      'Cette commande n’a pas été réglée en fin de soirée. Elle reste due — merci de vous rapprocher de l’établissement.',
    noteLabel: 'Note :',
    paidAtBar: 'Réglée au bar — merci !',
    pdfRecap: 'Récapitulatif PDF',
    rateService: 'Noter le service',
    stReceived: 'Reçue',
    stInPrep: 'En préparation',
    stInPrepShort: 'En prépa',
    stReady: 'Prête à retirer',
    stReadyShort: 'Prête',
    stPickedUp: 'Retirée',
    stPaid: 'Réglée',
    stUnpaid: 'Impayée',
    stCancelled: 'Annulée',

    // Avis
    yourNight: 'Votre soirée',
    howWasService: 'Comment s’est passé le service ?',
    reviewPlaceholder: 'Un mot pour l’équipe (facultatif)',

    codeNotApplied:
      'Commande envoyée, mais le code n’a pas été appliqué (invalide, expiré ou conditions non remplies).',
    creditsExhausted:
      'Crédits épuisés — prochaine conso au prix carte, à régler lors du retrait de la commande.',
    notifReceivedTitle: 'Commande reçue',
    notifReceivedBody: (code) =>
      `Votre commande ${code} est bien arrivée au bar. Vous serez prévenu dès qu’elle est prête.`,

    // Erreurs métier
    err_pickup_pending:
      'Vous avez une commande prête à retirer. Récupérez-la d’abord au bar avant de pouvoir passer une nouvelle commande.',
    err_orders_closed: 'Les commandes sont fermées pour le moment.',
    err_empty_cart: 'Votre panier est vide.',
    err_product_unavailable: 'Un article de votre panier n’est plus disponible.',
    err_variant_required: 'Choisissez un format pour chaque article.',
    err_not_a_customer: 'Identifiez-vous pour commander.',
    err_forbidden: 'Action non autorisée.',
    err_scan_point_orphan:
      'Ce QR code ne pointe plus vers une soirée valide. Demandez au staff un QR à jour.',
    err_missing_profile: 'Prénom et nom sont obligatoires.',
    err_missing_phone: 'Numéro de téléphone obligatoire.',
    err_phone_already_used: 'Ce numéro est déjà utilisé par une autre fiche client.',
    err_missing_postal_code: 'Code postal obligatoire.',
    err_invalid_birthdate: 'Date de naissance invalide.',
    err_invalid_email: 'Adresse e-mail invalide.',
    err_code_exhausted: 'Ce code est épuisé : toutes ses utilisations ont déjà été activées.',
    err_invalid_pass_code: 'Code invalide, expiré ou déjà entièrement utilisé.',
    err_conversion_closed: 'La conversion du jeton food est fermée (disponible jusqu’à 22h).',
    err_no_food_token: 'Aucun jeton food disponible à convertir.',
    err_no_pass: 'Aucun forfait actif pour cette soirée.',
    err_unknown_order: 'Commande introuvable.',
    err_network: 'Connexion instable. Réessayez dans un instant.',
    err_generic: 'Une erreur est survenue.',
  },

  // --------------------------------------------------------------- ENGLISH
  en: {
    welcome: 'Welcome',
    start: 'Order',
    order: 'Order',
    cart: 'Cart',
    total: 'Total',
    send: 'Send order',
    sending: 'Sending…',
    soldOut: 'Sold out',
    note: 'Note for the bar',
    promo: 'Promo code',
    pickupCode: 'Pickup code',
    save: 'Save',
    sendShort: 'Send',
    add: 'Add',
    continue: 'Continue',
    removeCode: 'Remove',
    activate: 'Activate',
    seeMenu: 'See the menu',
    see: 'View',
    loadingMenu: 'Loading the menu…',
    opening: 'Opening…',
    backSoon: 'Welcome back…',
    unknownQr: 'Unknown QR code',

    payTitle: 'Payment at the bar',
    paySub: 'No online payment. You pay at the counter when you pick up your order.',
    ordersClosed: 'Orders are closed for now.',
    closedStillHere: 'The menu stays browsable, and the team can still write to you.',
    allMenuHere: 'The whole menu is ordered here, from your phone.',
    noQueueStrong: 'pick up',
    noQueueBottles: 'bottles',
    noQueue: (recup, bouteilles) =>
      `No more queueing: you only go to the bar to ${recup} your order, and for ${bouteilles} (served straight away).`,
    step1t: 'You order here',
    step1s: 'The whole menu, no queueing',
    step2t: 'The bar prepares it',
    step2s: 'You’re notified the moment it’s ready — stay where you are',
    step3t: 'You collect at the bar',
    step3s: 'With your code, no waiting',
    step4t: 'You pay on the spot',
    step4s: 'At the counter, as usual',

    identify: 'Let’s get to know you',
    identifySub: 'To order: your details, so we can call you at pickup and keep you posted.',
    firstName: 'First name',
    lastName: 'Last name',
    phone: 'Phone',
    postalCode: 'Postcode',
    birthdate: 'Date of birth',
    email: 'Email',
    instagram: 'Instagram',
    optional: 'Optional',
    addOptional: '+ Email / Instagram (optional — you can add them later)',
    cgu: 'By ordering, you accept our terms — pickup and payment at the bar are required.',
    dataEu: 'Data hosted in the European Union. No online payment.',
    errNames: 'First name and last name are required.',
    errPhone: 'Phone number required.',
    errPostal: 'Postcode required.',
    errBirth: 'Date of birth required.',
    errEmail: 'Invalid email address.',
    errBirthInvalid: 'Invalid date of birth — check the day, month and year.',

    gladToSeeYou: 'Good to see you again',
    backAgain: 'Welcome back',
    secondNight: 'Second night with us — glad to have you back.',
    nNights: (n) => `${n} nights spent with us. Thank you for your loyalty.`,
    vipStatus: 'VIP STATUS',
    unpaidPast:
      'An order from a previous night was left unpaid. Please settle it with the bar — the team will help you.',

    backHome: 'Back to home',
    backToTop: 'Back to top',
    back: 'Back',

    // Assistant
    assistantOpen: 'Need help?',
    assistantTitle: 'Noti Assistant',
    assistantIntro: 'A question about the menu, your order, or your credits? I’m here.',
    assistantPlaceholder: 'Type your question…',
    assistantSend: 'Send',
    assistantThinking: 'Thinking…',
    assistantError: 'The assistant is briefly unavailable. A team member can help you via Messages.',
    assistantSlowDown: 'That’s a lot of questions at once! Give me a moment, then ask again.',
    tabMenu: 'Menu',
    tabOrders: 'My orders',
    tabMessages: 'Messages',
    myAccount: 'My account',

    completeProfile: 'Complete your profile',
    fPostal: 'postcode',
    fBirth: 'date of birth',
    fEmail: 'email',
    fInstagram: 'Instagram',
    goToAccount: 'do it in your account',
    blockedStrong: 'You have an order ready for pickup.',
    blockedRest: 'Collect it at the bar first before placing a new order — code',
    newMessages: (n) => `${n} new message${s(n)} from the team`,
    nothingHere: 'Nothing in this selection',
    pushOk: 'You’ll be notified even with the screen locked.',
    pushKo: 'Notifications refused.',
    profileSaved: 'Profile updated.',
    reviewThanks: 'Thank you for your feedback!',

    popular: 'POPULAR',
    priceFrom: (p) => `from ${p}`,
    pickupFirst: 'Collect your ready order first',

    format: 'Size',
    requiredCaps: 'REQUIRED',
    optionalCaps: 'OPTIONAL',
    maxCaps: 'MAX',
    included: 'included',
    chooseFirst: (name) => `Choose: ${name}`,

    creditsIntroTitle: 'Your credits are ready',
    creditsIntroYouHave: (n) => `You have ${n} credit${s(n)}`,
    creditsIntroSoft: '1 credit = 1 soft drink',
    creditsIntroAlcohol: '2 credits = 1 alcoholic drink',
    creditsIntroHow:
      'They come off on their own when you add an item to your cart. Nothing else to do.',
    creditsIntroCta: 'See the menu',
    creditBadge: 'With your credits',
    myCredits: 'My credits',
    nAvailable: (n) => `${n} available`,
    nCredits: (n) => `${n} credit${s(n)}`,
    menuItem: 'item from the menu',
    ofChoice: (cat) => `${cat} of your choice`,
    creditAuto:
      'Your credits come off on their own when you add an item to your cart. 1 credit = 1 soft drink, 2 credits = 1 alcoholic drink.',
    promoPlaceholder: 'Discount, credit or group pass',
    promoCta: '🎟️ Got a promo code or a group pass? Activate it here',
    creditsAdded: 'Credits added — find them at the top of the menu!',
    passActivated: 'Pass activated!',
    codeActivated: 'Code activated!',
    codeAlreadyUsed: 'This code has already been used — your credits are unchanged.',
    activeCode: 'Active code',
    activePass: '🎟️ Active pass',
    creditsLeft: (n) => `${n} credit${s(n)} left`,
    foodToken: 'Food token',
    tokenAvailable: 'available',
    tokenUsed: 'used',
    convertToken: 'Convert my food token into 2 credits (1 alcoholic drink or 2 softs)',
    tokenConverted: 'Food token converted into 2 credits.',
    creditsEmpty: 'No credits left',
    nSofts: (n) => `${n} soft drink${s(n)}`,
    nAlcohols: (n) => `${n} alcoholic drink${s(n)}`,
    plusOneSoft: ' + 1 soft drink',
    orNSofts: (n) => `, or ${n} soft drink${s(n)}`,
    catFood: 'Food',
    catBottle: 'Bottle',
    catDrink: 'Drink',

    logout: 'Sign out of this device',
    logoutHint:
      'You will go back through the welcome screen and the sign-up form. Nothing is lost: enter the same phone number and you get your record, your orders and your credits back.',
    logoutConfirm:
      'Sign out of this device? You will have to enter your details again to order.',
    clientSpace: 'My account',
    yourInfo: 'Your details',
    myNights: (n) => `${n} night${s(n)} with us`,
    firstNight: 'First night with us',
    myOrdersHere: 'Your orders tonight',
    noOrdersHere: 'No orders tonight yet.',
    creditsNone: 'No credits at the moment',

    emptyCart: 'Empty cart',

    validateOrder: 'Confirm your order',
    notePlaceholder: 'No ice, less sugar, allergy…',
    checkingCode: (c) => `Checking code ${c}…`,
    creditsLeftAfter: (n) =>
      n > 0
        ? `You will have ${n} credit${n > 1 ? 's' : ''} left after this order.`
        : 'Your credits will be used up after this order.',
    codeApplied: (c, v) => `Code ${c} — ${v} discount applied below.`,
    codeInvalid: (c) => `Code ${c} is invalid, expired, used up, or your cart is too small for it.`,
    readyIn: (min) => `Ready in about ${min} min.`,
    pickup5:
      'Please collect your order within 5 minutes once it is ready — it remains due even if it is not collected.',

    noMessages: 'No messages yet',
    noMessagesSub: 'Announcements for the night and messages addressed to you will appear here.',
    msgForYou: 'Message for you',
    msgOrder: 'Order update',
    seeMyOrder: 'View my order',
    msgUrgent: 'Urgent message',
    newUrgent: (n) => `${n} urgent message${s(n)}`,
    announcement: 'Announcement',
    markRead: 'Mark as read',

    noOrders: 'No orders yet',
    noOrdersSub: 'Your orders for the night will appear here.',
    notifOn: '✓ Notifications on',
    notifCta: 'Notify me when it’s ready',
    showCodeAtBar: 'Show this code at the bar and pay there',
    orderedAt: (h) => `Ordered at ${h}`,

    delayNotes: [
      'Time for one more dance 💃 your order isn’t ready yet.',
      'The bar is packed 🍸 another track or two and it’s yours.',
      'Running a little late, thanks for the patience — we’re on it.',
      'We haven’t forgotten you, there’s just a queue ahead 🙃',
      'Taking a bit longer than expected. Good time to put the world to rights.',
      'The shaker is working! Just a moment longer.',
    ],
    delayNoteLate: 'Alright, this really is taking a while 😅 the whole team is on it.',
    delayBadge: 'Running late',
    unpaidOrder:
      'This order was not paid at the end of the night. It remains due — please get in touch with the venue.',
    noteLabel: 'Note:',
    paidAtBar: 'Paid at the bar — thank you!',
    pdfRecap: 'PDF summary',
    rateService: 'Rate the service',
    stReceived: 'Received',
    stInPrep: 'Being prepared',
    stInPrepShort: 'Preparing',
    stReady: 'Ready for pickup',
    stReadyShort: 'Ready',
    stPickedUp: 'Collected',
    stPaid: 'Paid',
    stUnpaid: 'Unpaid',
    stCancelled: 'Cancelled',

    yourNight: 'Your night',
    howWasService: 'How was the service?',
    reviewPlaceholder: 'A word for the team (optional)',

    codeNotApplied:
      'Order sent, but the code was not applied (invalid, expired, or conditions not met).',
    creditsExhausted:
      'No credits left — your next drink is at menu price, to be paid when you collect the order.',
    notifReceivedTitle: 'Order received',
    notifReceivedBody: (code) =>
      `Your order ${code} has reached the bar. We'll let you know as soon as it is ready.`,

    err_pickup_pending:
      'You have an order ready for pickup. Collect it at the bar first before placing a new one.',
    err_orders_closed: 'Orders are closed for now.',
    err_empty_cart: 'Your cart is empty.',
    err_product_unavailable: 'An item in your cart is no longer available.',
    err_variant_required: 'Choose a size for each item.',
    err_not_a_customer: 'Identify yourself to order.',
    err_forbidden: 'Action not allowed.',
    err_scan_point_orphan:
      'This QR code no longer points to a valid night. Ask the staff for an up-to-date QR.',
    err_missing_profile: 'First name and last name are required.',
    err_missing_phone: 'Phone number required.',
    err_phone_already_used: 'This number is already used by another customer record.',
    err_missing_postal_code: 'Postcode required.',
    err_invalid_birthdate: 'Invalid date of birth.',
    err_invalid_email: 'Invalid email address.',
    err_code_exhausted: 'This code is used up: all of its uses have already been activated.',
    err_invalid_pass_code: 'Code invalid, expired or already fully used.',
    err_conversion_closed: 'Food token conversion is closed (available until 10pm).',
    err_no_food_token: 'No food token available to convert.',
    err_no_pass: 'No active pass for this night.',
    err_unknown_order: 'Order not found.',
    err_network: 'Unstable connection. Try again in a moment.',
    err_generic: 'Something went wrong.',
  },

  // --------------------------------------------------------------- ESPAÑOL
  es: {
    welcome: 'Bienvenido',
    start: 'Pedir',
    order: 'Pedir',
    cart: 'Carrito',
    total: 'Total',
    send: 'Enviar pedido',
    sending: 'Enviando…',
    soldOut: 'Agotado',
    note: 'Nota para la barra',
    promo: 'Código promocional',
    pickupCode: 'Código de recogida',
    save: 'Guardar',
    sendShort: 'Enviar',
    add: 'Añadir',
    continue: 'Continuar',
    removeCode: 'Quitar',
    activate: 'Activar',
    seeMenu: 'Ver la carta',
    see: 'Ver',
    loadingMenu: 'Cargando la carta…',
    opening: 'Abriendo…',
    backSoon: 'Bienvenido de nuevo…',
    unknownQr: 'Código QR desconocido',

    payTitle: 'Pago en la barra',
    paySub: 'Sin pago en línea. Pagas en el mostrador al recoger tu pedido.',
    ordersClosed: 'Los pedidos están cerrados por ahora.',
    closedStillHere: 'La carta sigue disponible y el equipo aún puede escribirte.',
    allMenuHere: 'Toda la carta se pide aquí, desde tu móvil.',
    noQueueStrong: 'recoger',
    noQueueBottles: 'botellas',
    noQueue: (recup, bouteilles) =>
      `Sin colas: solo vas a la barra para ${recup} tu pedido, y para las ${bouteilles} (servidas al momento).`,
    step1t: 'Pides aquí',
    step1s: 'Toda la carta, sin hacer cola',
    step2t: 'La barra lo prepara',
    step2s: 'Te avisamos en cuanto esté listo — quédate donde estás',
    step3t: 'Recoges en la barra',
    step3s: 'Con tu código, sin esperar',
    step4t: 'Pagas allí mismo',
    step4s: 'En el mostrador, como siempre',

    identify: 'Vamos a conocernos',
    identifySub: 'Para pedir: tus datos, para avisarte al recoger y mantenerte informado.',
    firstName: 'Nombre',
    lastName: 'Apellido',
    phone: 'Teléfono',
    postalCode: 'Código postal',
    birthdate: 'Fecha de nacimiento',
    email: 'Correo electrónico',
    instagram: 'Instagram',
    optional: 'Opcional',
    addOptional: '+ Correo / Instagram (opcional — puedes añadirlos después)',
    cgu: 'Al pedir, aceptas nuestras condiciones — la recogida y el pago en la barra son obligatorios.',
    dataEu: 'Datos alojados en la Unión Europea. Sin pago en línea.',
    errNames: 'El nombre y el apellido son obligatorios.',
    errPhone: 'Número de teléfono obligatorio.',
    errPostal: 'Código postal obligatorio.',
    errBirth: 'Fecha de nacimiento obligatoria.',
    errEmail: 'Correo electrónico no válido.',
    errBirthInvalid: 'Fecha de nacimiento no válida — revisa el día, el mes y el año.',

    gladToSeeYou: 'Encantados de verte de nuevo',
    backAgain: 'Bienvenido de nuevo',
    secondNight: 'Segunda noche con nosotros — nos alegra verte.',
    nNights: (n) => `${n} noches con nosotros. Gracias por tu fidelidad.`,
    vipStatus: 'ESTATUS VIP',
    unpaidPast:
      'Un pedido de una noche anterior quedó sin pagar. Regularízalo en la barra — el equipo te ayudará.',

    backHome: 'Volver al inicio',
    backToTop: 'Volver arriba',
    back: 'Volver',

    // Asistente
    assistantOpen: '¿Necesitas ayuda?',
    assistantTitle: 'Asistente Noti',
    assistantIntro: '¿Una pregunta sobre la carta, tu pedido o tus créditos? Estoy aquí.',
    assistantPlaceholder: 'Escribe tu pregunta…',
    assistantSend: 'Enviar',
    assistantThinking: 'Respondiendo…',
    assistantError: 'El asistente no está disponible por el momento. Un miembro del equipo puede ayudarte en Mensajes.',
    assistantSlowDown: '¡Cuántas preguntas de golpe! Dame un momento y vuelve a preguntar.',
    tabMenu: 'La carta',
    tabOrders: 'Mis pedidos',
    tabMessages: 'Mensajes',
    myAccount: 'Mi cuenta',

    completeProfile: 'Completa tu perfil',
    fPostal: 'código postal',
    fBirth: 'fecha de nacimiento',
    fEmail: 'correo electrónico',
    fInstagram: 'Instagram',
    goToAccount: 'hazlo en tu cuenta',
    blockedStrong: 'Tienes un pedido listo para recoger.',
    blockedRest: 'Recógelo primero en la barra antes de hacer un pedido nuevo — código',
    newMessages: (n) => `${n} mensaje${s(n)} nuevo${s(n)} del equipo`,
    nothingHere: 'Nada en esta selección',
    pushOk: 'Te avisaremos incluso con la pantalla bloqueada.',
    pushKo: 'Notificaciones rechazadas.',
    profileSaved: 'Perfil actualizado.',
    reviewThanks: '¡Gracias por tu comentario!',

    popular: 'POPULAR',
    priceFrom: (p) => `desde ${p}`,
    pickupFirst: 'Recoge antes tu pedido listo',

    format: 'Formato',
    requiredCaps: 'OBLIGATORIO',
    optionalCaps: 'OPCIONAL',
    maxCaps: 'MÁX',
    included: 'incluido',
    chooseFirst: (name) => `Elige: ${name}`,

    creditsIntroTitle: 'Tus créditos están listos',
    creditsIntroYouHave: (n) => `Tienes ${n} crédito${s(n)}`,
    creditsIntroSoft: '1 crédito = 1 refresco',
    creditsIntroAlcohol: '2 créditos = 1 bebida alcohólica',
    creditsIntroHow:
      'Se descuentan solos al añadir un artículo al carrito. No hay nada más que hacer.',
    creditsIntroCta: 'Ver la carta',
    creditBadge: 'Con tus créditos',
    myCredits: 'Mis créditos',
    nAvailable: (n) => `${n} disponible${s(n)}`,
    nCredits: (n) => `${n} crédito${s(n)}`,
    menuItem: 'artículo de la carta',
    ofChoice: (cat) => `${cat} a elegir`,
    creditAuto:
      'Tus créditos se descuentan solos al añadir un artículo al carrito. 1 crédito = 1 refresco, 2 créditos = 1 bebida alcohólica.',
    promoPlaceholder: 'Descuento, crédito o bono',
    promoCta: '🎟️ ¿Tienes un código o un bono de grupo? Actívalo aquí',
    creditsAdded: '¡Créditos añadidos — los verás arriba de la carta!',
    passActivated: '¡Bono activado!',
    codeActivated: '¡Código activado!',
    codeAlreadyUsed: 'Este código ya se ha usado — tus créditos no han cambiado.',
    activeCode: 'Código activo',
    activePass: '🎟️ Bono activo',
    creditsLeft: (n) => `${n} crédito${s(n)} restante${s(n)}`,
    foodToken: 'Ficha de comida',
    tokenAvailable: 'disponible',
    tokenUsed: 'usada',
    convertToken: 'Convertir mi ficha de comida en 2 créditos (1 alcohol o 2 refrescos)',
    tokenConverted: 'Ficha de comida convertida en 2 créditos.',
    creditsEmpty: 'Sin créditos',
    nSofts: (n) => `${n} refresco${s(n)}`,
    nAlcohols: (n) => `${n} bebida${s(n)} alcohólica${s(n)}`,
    plusOneSoft: ' + 1 refresco',
    orNSofts: (n) => `, o ${n} refresco${s(n)}`,
    catFood: 'Comida',
    catBottle: 'Botella',
    catDrink: 'Bebida',

    logout: 'Cerrar sesión en este dispositivo',
    logoutHint:
      'Volverás a pasar por la pantalla de inicio y el formulario de registro. No se pierde nada: con el mismo número de teléfono recuperas tu ficha, tus pedidos y tus créditos.',
    logoutConfirm:
      '¿Cerrar sesión en este dispositivo? Tendrás que volver a introducir tus datos para pedir.',
    clientSpace: 'Mi cuenta',
    yourInfo: 'Tus datos',
    myNights: (n) => `${n} noche${s(n)} con nosotros`,
    firstNight: 'Primera noche con nosotros',
    myOrdersHere: 'Tus pedidos de esta noche',
    noOrdersHere: 'Todavía no hay pedidos esta noche.',
    creditsNone: 'Sin créditos por ahora',

    emptyCart: 'Carrito vacío',

    validateOrder: 'Confirmar el pedido',
    notePlaceholder: 'Sin hielo, poco azúcar, alergia…',
    checkingCode: (c) => `Comprobando el código ${c}…`,
    creditsLeftAfter: (n) =>
      n > 0
        ? `Te quedarán ${n} crédito${n > 1 ? 's' : ''} después de este pedido.`
        : 'Tus créditos se agotarán después de este pedido.',
    codeApplied: (c, v) => `Código ${c} — descuento de ${v} aplicado abajo.`,
    codeInvalid: (c) => `Código ${c} no válido, caducado, agotado o carrito insuficiente.`,
    readyIn: (min) => `Listo en unos ${min} min.`,
    pickup5:
      'Recoge tu pedido en los 5 minutos siguientes a estar listo — se debe igualmente aunque no se recoja.',

    noMessages: 'Todavía no hay mensajes',
    noMessagesSub: 'Los anuncios de la noche y los mensajes dirigidos a ti aparecerán aquí.',
    msgForYou: 'Mensaje para ti',
    msgOrder: 'Seguimiento del pedido',
    seeMyOrder: 'Ver mi pedido',
    msgUrgent: 'Mensaje urgente',
    newUrgent: (n) => `${n} mensaje${s(n)} urgente${s(n)}`,
    announcement: 'Anuncio de la noche',
    markRead: 'Marcar como leído',

    noOrders: 'Todavía no hay pedidos',
    noOrdersSub: 'Tus pedidos de la noche aparecerán aquí.',
    notifOn: '✓ Notificaciones activadas',
    notifCta: 'Avísame cuando esté listo',
    showCodeAtBar: 'Muestra este código en la barra y paga allí',
    orderedAt: (h) => `Pedido de las ${h}`,

    delayNotes: [
      'Te da tiempo a bailar otra 💃 tu pedido aún no está listo.',
      'La barra está a tope 🍸 una canción más y es tuyo.',
      'Un pelín de retraso, mucha sed — vamos a por ello.',
      'No nos hemos olvidado de ti, es que hay cola 🙃',
      'Está tardando un poco más de lo previsto. Aprovecha para arreglar el mundo.',
      '¡La coctelera no para! Un momentito más.',
    ],
    delayNoteLate: 'Vale, esto se está alargando de verdad 😅 todo el equipo está en ello.',
    delayBadge: 'Con algo de retraso',
    unpaidOrder:
      'Este pedido no se pagó al final de la noche. Sigue pendiente — ponte en contacto con el local.',
    noteLabel: 'Nota:',
    paidAtBar: 'Pagado en la barra — ¡gracias!',
    pdfRecap: 'Resumen en PDF',
    rateService: 'Valorar el servicio',
    stReceived: 'Recibido',
    stInPrep: 'En preparación',
    stInPrepShort: 'Preparando',
    stReady: 'Listo para recoger',
    stReadyShort: 'Listo',
    stPickedUp: 'Recogido',
    stPaid: 'Pagado',
    stUnpaid: 'Sin pagar',
    stCancelled: 'Cancelado',

    yourNight: 'Tu noche',
    howWasService: '¿Qué tal ha ido el servicio?',
    reviewPlaceholder: 'Unas palabras para el equipo (opcional)',

    codeNotApplied:
      'Pedido enviado, pero el código no se ha aplicado (no válido, caducado o condiciones no cumplidas).',
    creditsExhausted:
      'Sin créditos — la próxima consumición va a precio de carta, a pagar al recoger el pedido.',
    notifReceivedTitle: 'Pedido recibido',
    notifReceivedBody: (code) =>
      `Tu pedido ${code} ha llegado a la barra. Te avisaremos en cuanto esté listo.`,

    err_pickup_pending:
      'Tienes un pedido listo para recoger. Recógelo primero en la barra antes de hacer uno nuevo.',
    err_orders_closed: 'Los pedidos están cerrados por ahora.',
    err_empty_cart: 'Tu carrito está vacío.',
    err_product_unavailable: 'Un artículo de tu carrito ya no está disponible.',
    err_variant_required: 'Elige un formato para cada artículo.',
    err_not_a_customer: 'Identifícate para pedir.',
    err_forbidden: 'Acción no permitida.',
    err_scan_point_orphan:
      'Este código QR ya no corresponde a una noche válida. Pide al personal un QR actualizado.',
    err_missing_profile: 'El nombre y el apellido son obligatorios.',
    err_missing_phone: 'Número de teléfono obligatorio.',
    err_phone_already_used: 'Este número ya lo usa otra ficha de cliente.',
    err_missing_postal_code: 'Código postal obligatorio.',
    err_invalid_birthdate: 'Fecha de nacimiento no válida.',
    err_invalid_email: 'Correo electrónico no válido.',
    err_code_exhausted: 'Este código está agotado: ya se han usado todas sus activaciones.',
    err_invalid_pass_code: 'Código no válido, caducado o ya usado por completo.',
    err_conversion_closed: 'La conversión de la ficha de comida está cerrada (hasta las 22 h).',
    err_no_food_token: 'No hay ficha de comida para convertir.',
    err_no_pass: 'No hay ningún bono activo para esta noche.',
    err_unknown_order: 'Pedido no encontrado.',
    err_network: 'Conexión inestable. Vuelve a intentarlo en un momento.',
    err_generic: 'Se ha producido un error.',
  },
}

// Le français fait office de filet : une clé oubliée dans une traduction
// affiche le libellé français plutôt qu'un « undefined » à l'écran.
const MERGED = {
  fr: T.fr,
  en: { ...T.fr, ...T.en },
  es: { ...T.fr, ...T.es },
}

/** Dictionnaire complet pour une langue (français par défaut). */
export const dict = (lang) => MERGED[lang] || MERGED.fr

/** Même chose, nommé pour l'usage dans les composants. */
export const useT = (lang) => dict(lang)

/** Traduction d'un produit selon la langue choisie (saisie côté staff). */
export function trProduct(p, lang) {
  if (!p) return { name: '', description: '' }
  if (!lang || lang === 'fr') return { name: p.name, description: p.description }
  const t = p.translations?.[lang]
  return { name: t?.name || p.name, description: t?.description || p.description }
}
