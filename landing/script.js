// Chebit landing: the theme toggle and the pilot form. No dependencies.

// ---------- theme ----------
// Light is the default. The toggle stores the choice.
const themeToggle = document.getElementById("theme-toggle");

themeToggle.addEventListener("click", function () {
  const root = document.documentElement;
  const nextTheme = root.dataset.theme === "dark" ? "light" : "dark";
  root.dataset.theme = nextTheme;
  try {
    localStorage.setItem("chebit-theme", nextTheme);
  } catch (error) {
    // Storage can be blocked. The toggle still works for this visit.
  }
});

// ---------- pilot form ----------
// The form sends nothing to a server. It opens WhatsApp with the message
// written, addressed to the number in the form's data-whatsapp attribute.
const pilotForm = document.getElementById("pilot-form");
const formNote = document.getElementById("form-note");

pilotForm.addEventListener("submit", function (event) {
  event.preventDefault();

  const fields = new FormData(pilotForm);
  const business = String(fields.get("comercio") || "").trim();
  const city = String(fields.get("ciudad") || "").trim();
  const contact = String(fields.get("contacto") || "").trim();

  if (!business || !city || !contact) {
    formNote.textContent = "Completá los tres campos.";
    return;
  }

  const whatsappNumber = pilotForm.dataset.whatsapp;
  if (!whatsappNumber) {
    formNote.textContent = "El formulario todavía no está conectado.";
    return;
  }

  const message = [
    "Hola, quiero sumar mi comercio al piloto de Chebit.",
    "Comercio: " + business,
    "Ciudad: " + city,
    "Contacto: " + contact,
  ].join("\n");

  const link = "https://wa.me/" + whatsappNumber + "?text=" + encodeURIComponent(message);
  window.open(link, "_blank", "noopener");
  formNote.textContent = "Se abrió WhatsApp con tu mensaje. Envialo para terminar.";
});
