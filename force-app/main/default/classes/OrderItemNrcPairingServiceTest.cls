@IsTest
private class OrderItemNrcPairingServiceTest {

    // ─── pairNrcOrderItems — boundary inputs ─────────────────────────────────

    @IsTest
    static void pairNrcOrderItems_nullInput() {
        Test.startTest();
        OrderItemNrcPairingService.pairNrcOrderItems(null);
        Test.stopTest();
        // No exception = pass
    }

    @IsTest
    static void pairNrcOrderItems_emptyList() {
        Test.startTest();
        OrderItemNrcPairingService.pairNrcOrderItems(
            new List<OrderItemNrcPairingService.Request>()
        );
        Test.stopTest();
        // No exception = pass
    }

    @IsTest
    static void pairNrcOrderItems_nullOrderId() {
        OrderItemNrcPairingService.Request req = new OrderItemNrcPairingService.Request();
        req.orderId = null;
        Test.startTest();
        OrderItemNrcPairingService.pairNrcOrderItems(
            new List<OrderItemNrcPairingService.Request>{ req }
        );
        Test.stopTest();
        // No exception = pass
    }
}