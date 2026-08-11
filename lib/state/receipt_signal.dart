// How far a peer has got with our messages, as the two words a transcript can
// show for it.
//
// The receipt envelope itself -- its `v: 2` wire shape, its encoding and its
// decoding -- belongs to the core now (freizone-server's pkg/client, see
// SendReceipt and SendGroupReceipt). What stays here is the vocabulary the
// screens speak: a watermark is one marker per conversation ("everything up to
// this instant"), never one receipt per message, and a bubble renders as
// delivered or as read.
library;

enum ReceiptStatus { delivered, read }
