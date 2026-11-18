# Runs inside the authentik container via `ak shell -c`.
from authentik.flows.models import (
    Flow,
    FlowDesignation,
    FlowAuthenticationRequirement,
    FlowStageBinding,
)
from authentik.policies.expression.models import ExpressionPolicy
from authentik.stages.prompt.models import Prompt, PromptStage, FieldTypes
from authentik.stages.user_write.models import UserWriteStage, UserCreationMode
from authentik.stages.user_login.models import UserLoginStage
from authentik.stages.identification.models import IdentificationStage

def ensure_prompt(name, key, label, ftype, order=0, required=True):
    p, _ = Prompt.objects.update_or_create(
        name=name,
        defaults={
            "field_key": key,
            "label": label,
            "type": ftype,
            "required": required,
            "placeholder": label,
            "placeholder_expression": False,
            "order": order,
        },
    )
    return p

p_user = ensure_prompt(
    "self-hosted-enrollment-field-username", "username", "Username", FieldTypes.USERNAME, 0
)
p_pass = ensure_prompt(
    "self-hosted-enrollment-field-password", "password", "Password", FieldTypes.PASSWORD, 0
)
p_pass2 = ensure_prompt(
    "self-hosted-enrollment-field-password-repeat",
    "password_repeat",
    "Password (repeat)",
    FieldTypes.PASSWORD,
    1,
)
# Display name is hidden and copied from the username, so signup asks for the
# name once (on the same page as the password).
p_name = ensure_prompt(
    "self-hosted-enrollment-field-name", "name", "Name", FieldTypes.HIDDEN, 2, required=False
)
# Hidden fields send their placeholder as the value; the policy fills the name.
p_name.placeholder = ""
p_name.placeholder_expression = False
p_name.initial_value = ""
p_name.initial_value_expression = False
p_name.save()

name_policy, _ = ExpressionPolicy.objects.update_or_create(
    name="self-hosted-enrollment-name-from-username",
    defaults={
        "expression": (
            "prompt_data = request.context.get(\"prompt_data\", {})\n"
            "if not prompt_data.get(\"name\"):\n"
            "    prompt_data[\"name\"] = prompt_data.get(\"username\", \"\")\n"
            "return True"
        ),
    },
)

ps1, _ = PromptStage.objects.update_or_create(name="self-hosted-enrollment-prompt-first")
ps1.fields.set([p_user, p_pass, p_pass2, p_name])
ps1.validation_policies.set([name_policy])

# 2026.x defaults user_type to external, which denies the user interface.
uw, _ = UserWriteStage.objects.update_or_create(
    name="self-hosted-enrollment-user-write",
    defaults={
        "user_creation_mode": UserCreationMode.ALWAYS_CREATE,
        "user_type": "internal",
    },
)
ul, _ = UserLoginStage.objects.update_or_create(name="self-hosted-enrollment-user-login")

flow, _ = Flow.objects.update_or_create(
    slug="default-enrollment-flow",
    defaults={
        "name": "Self-hosted enrollment",
        "title": "Create an account",
        "designation": FlowDesignation.ENROLLMENT,
        "authentication": FlowAuthenticationRequirement.REQUIRE_UNAUTHENTICATED,
    },
)
FlowStageBinding.objects.filter(target=flow).delete()
# Old second prompt stage (separate name page) is no longer used.
PromptStage.objects.filter(name="self-hosted-enrollment-prompt-second").delete()
for order, stage in ((10, ps1), (20, uw), (100, ul)):
    FlowStageBinding.objects.create(target=flow, stage=stage, order=order)

ident = IdentificationStage.objects.get(name="default-authentication-identification")
ident.user_fields = ["username", "email"]
ident.enrollment_flow = flow
ident.save()
print("signup ready: /if/flow/default-enrollment-flow/")
