using Microsoft.VisualStudio.TestTools.UnitTesting;

[TestClass]
public sealed class Smoke
{
    [TestMethod] public void BclArithmetic() => Assert.AreEqual(4, 2 + 2);
    [TestMethod] public void ExplicitlySelectedFailure() => Assert.Fail("Synthetic intentional native test failure");
}
