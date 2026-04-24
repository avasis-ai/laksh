(function () {
  var y = document.getElementById("year");
  if (y) {
    y.textContent = String(new Date().getFullYear());
  }

  var reduceMotion =
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  if (!reduceMotion) {
    var revealables = Array.prototype.slice.call(document.querySelectorAll(".reveal"));
    if ("IntersectionObserver" in window && revealables.length) {
      var io = new IntersectionObserver(
        function (entries) {
          entries.forEach(function (e) {
            if (e.isIntersecting) {
              e.target.classList.add("is-visible");
              io.unobserve(e.target);
            }
          });
        },
        { root: null, rootMargin: "0px 0px -8% 0px", threshold: 0.12 }
      );
      revealables.forEach(function (el) {
        io.observe(el);
      });
    } else {
      revealables.forEach(function (el) {
        el.classList.add("is-visible");
      });
    }
  } else {
    Array.prototype.forEach.call(document.querySelectorAll(".reveal"), function (el) {
      el.classList.add("is-visible");
    });
  }
})();
