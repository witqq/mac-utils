import MacUtilsSystem
import Testing

@Test
func systemModuleCanUseCoreDomain() {
    #expect(SystemEnvironment.productName == "Mac Utils")
}
